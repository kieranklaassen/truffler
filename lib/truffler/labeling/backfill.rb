module Truffler
  module Labeling
    # Relabels one model's records whose labels are missing, stale (labeled
    # under another vocabulary version), failed, or demoted to backfill
    # priority. It walks newest-first below an id cursor, splits each page by
    # tenant, packs batch_size records per request at backfill priority, and
    # asks only the stale questions. Live pending rows belong to the flush job
    # and are never touched.
    #
    # Resumable: the cursor moves past a page only once the whole page is
    # done, and records already current are skipped, so a rerun never asks
    # Jev about them again. A spend cap stops the run before a request would
    # exceed it. A Jev error releases the claimed rows and ends the run with
    # `:client_error`, so the caller keeps the spend metered so far.
    class Backfill
      Result = Data.define(:status, :labeled, :requests, :cost, :cursor)

      STATES = Records::RecordState.table_name

      class SpendCapReached < StandardError; end

      # Wraps the client to meter spend per request and refuse a request whose
      # estimated cost would push spend past the cap.
      class SpendMeter
        attr_reader :spent, :requests

        def initialize(client, cap:, spent:, config: Truffler.config)
          @client = client
          @cap = cap
          @spent = spent.to_f
          @requests = 0
          @config = config
        end

        def ask(state:, questions:, **options)
          raise SpendCapReached if @cap && @spent + estimate(state, questions) > @cap

          answers = @client.ask(state: state, questions: questions, **options)
          @requests += 1
          @spent += answers.usage&.cost.to_f
          answers
        end

        def exhausted?
          @cap.present? && @spent >= @cap
        end

        private

        def estimate(state, questions)
          @config.cost_for(Tokens.estimate({ state: state, questions: questions }))
        end
      end

      def self.status(model)
        new(model).status
      end

      attr_reader :model, :batch_size, :page_size

      def initialize(model, spend_cap: Truffler.config.backfill_spend_cap, batch_size: Truffler.config.batch_size,
        page_size: nil, cursor: nil, spent: 0.0, client: Truffler.config.client, budget: Budget.new)
        @model = model
        @batch_size = batch_size
        @page_size = page_size || batch_size * 5
        @cursor = cursor
        @meter = SpendMeter.new(client, cap: spend_cap, spent: spent)
        @budget = budget
        @versions = {}
      end

      def run(max_pages: nil)
        @labeled = 0
        @started_spent = @meter.spent
        cursor = @cursor
        pages = 0

        loop do
          scanned, rows = page(cursor)
          return result(:complete, nil) if scanned.empty?
          return result(:paused, cursor) if max_pages && pages >= max_pages

          rows.group_by(&:last).each do |tenant_key, tenant_rows|
            tenant_rows.map(&:first).each_slice(batch_size) do |ids|
              return result(:spend_cap_reached, cursor) if @meter.exhausted?

              stop = label(ids, tenant_key)
              return result(stop, cursor) if stop
            end
          end

          cursor = scanned.last
          pages += 1
          return result(:complete, nil) if scanned.size < page_size
        end
      end

      def status
        counts = states.group(:status).count
        labeled = states.where(status: "labeled").group(:tenant_key, :vocabulary_version).count
        stale = labeled.sum { |(tenant_key, version), count| version == version_for(tenant_key) ? 0 : count }
        { total: model.count, missing: model.joins(state_join).where("#{STATES}.id IS NULL").count,
          pending: counts["pending"].to_i, labeling: counts["labeling"].to_i, labeled: counts["labeled"].to_i,
          failed: counts["failed"].to_i, stale: stale, current: labeled.values.sum - stale }
      end

      private

      def definition
        model.truffler_definition
      end

      def record_type
        model.polymorphic_name
      end

      def states
        Records::RecordState.for_model(model)
      end

      def queue
        @queue ||= Queue.new(model)
      end

      def version_for(tenant_key)
        @versions[tenant_key] ||= definition.vocabulary.version(tenant_key: tenant_key, all_users: true)
      end

      def result(status, cursor)
        Result.new(status: status, labeled: @labeled, requests: @meter.requests, cost: @meter.spent - @started_spent,
          cursor: cursor)
      end

      # Returns the scanned ids (for the cursor) and the [id, tenant_key] rows
      # that still need labels. Per-tenant vocabularies (per-tenant choices or
      # lenses) compare versions here because each tenant has its own.
      def page(cursor)
        pk = model.primary_key
        scope = model.joins(state_join).where(needs_labeling_sql)
        scope = scope.where(model.arel_table[pk].lt(cursor)) if cursor
        tenant = definition.scoped? ? model.arel_table[definition.tenant_column] : Arel.sql("NULL")
        plucked = scope.reorder(pk => :desc).limit(page_size)
          .pluck(model.arel_table[pk], tenant, Arel.sql("#{STATES}.status"), Arel.sql("#{STATES}.vocabulary_version"))

        rows = plucked.filter_map do |id, tenant_key, status, version|
          tenant_key = tenant_key&.to_s
          [ id, tenant_key ] unless status == "labeled" && version == version_for(tenant_key)
        end
        [ plucked.map(&:first), rows ]
      end

      def state_join
        pk = "#{model.quoted_table_name}.#{model.connection.quote_column_name(model.primary_key)}"
        ActiveRecord::Base.sanitize_sql_array([
          "LEFT OUTER JOIN #{STATES} ON #{STATES}.record_type = ? AND #{STATES}.record_id = #{pk}", record_type
        ])
      end

      def needs_labeling_sql
        stale = if definition.per_tenant_vocabulary? || Lenses::Lens.active.for_model(model).exists?
          "#{STATES}.status = 'labeled'"
        else
          ActiveRecord::Base.sanitize_sql_array([
            "(#{STATES}.status = 'labeled' AND (#{STATES}.vocabulary_version IS NULL OR #{STATES}.vocabulary_version <> ?))",
            version_for(nil)
          ])
        end
        "#{STATES}.id IS NULL OR #{STATES}.status = 'failed' OR " \
          "(#{STATES}.status = 'pending' AND #{STATES}.priority = 'backfill') OR #{stale}"
      end

      # Labels one tenant chunk. Returns nil when done, or the status that
      # stops the run; claimed rows that were not labeled go back to pending
      # at backfill priority.
      def label(ids, tenant_key)
        claimed = queue.claim_backfill(ids, tenant_key)
        return if claimed.empty?

        begin
          Labeler.new(model, client: @meter, budget: @budget).label(claimed, priority: :backfill)
        rescue BudgetExhausted, SpendCapReached => error
          queue.demote(claimed)
          return error.is_a?(SpendCapReached) ? :spend_cap_reached : :budget_denied
        rescue ClientError, IncompleteAnswers => error
          queue.release(claimed, error)
          return :client_error
        ensure
          @labeled += Records::RecordState.where(id: claimed.map(&:id), status: "labeled").count
        end
        nil
      end
    end
  end
end
