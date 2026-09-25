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
    # exceed it; host-supplied labels cost nothing, so they are still written
    # once the cap is reached. The cap counts everything spent under the
    # model's current app-wide vocabulary version, kept in the
    # truffler_backfill_spends ledger, so reruns and overlapping jobs share
    # it; without that table it falls back to this run plus `spent:`. A Jev error releases the claimed rows and ends
    # the run with `:client_error`, so the caller keeps the spend metered so far.
    #
    # A budget denial ends the run with `:budget_denied`, unless the run
    # waits: then it backs off (see .backoff) and retries from the same
    # cursor until it completes, reaches the spend cap, or runs out of
    # `max_duration` seconds, which pauses it with the cursor to resume from.
    class Backfill
      Result = Data.define(:status, :labeled, :requests, :cost, :cursor, :retry_after)

      INITIAL_BACKOFF = 1.0
      MAX_BACKOFF = 30.0

      class_attribute :sleeper, default: ->(seconds) { sleep(seconds) }
      class_attribute :clock, default: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      STATES = Records::RecordState.table_name

      class SpendCapReached < StandardError; end

      # Wraps the client to meter spend per request and refuse a request whose
      # estimated cost would push spend past the cap. With a ledger the
      # estimate is reserved in SQL before the request and settled to the
      # reported cost after it, so concurrent meters on one ledger never
      # both take the last of the cap.
      class SpendMeter
        attr_reader :requests, :cost

        def initialize(client, cap:, spent:, ledger: nil, config: Truffler.config)
          @client = client
          @cap = cap
          @spent = spent.to_f
          @ledger = ledger
          @requests = 0
          @cost = 0.0
          @config = config
        end

        def spent
          @ledger ? @ledger.total : @spent
        end

        def ask(state:, questions:, **options)
          estimate = estimate(state, questions)
          reserve(estimate)
          answers = nil
          begin
            answers = @client.ask(state: state, questions: questions, **options)
          ensure
            @ledger&.settle(-estimate, requests: 0) unless answers
          end
          record(answers.usage&.cost.to_f, estimate)
          answers
        end

        private

        def record(cost, estimate)
          @requests += 1
          @cost += cost
          if @ledger
            @ledger.settle(cost - estimate)
          else
            @spent += cost
          end
        end

        def reserve(estimate)
          if @ledger
            raise SpendCapReached unless @ledger.reserve(estimate, @cap)
          elsif @cap && @spent + estimate > @cap
            raise SpendCapReached
          end
        end

        def estimate(state, questions)
          @config.cost_for(Tokens.estimate({ state: state, questions: questions }))
        end
      end

      def self.status(model)
        new(model).status
      end

      # The ledger row for the model's current vocabulary version, or nil
      # when nothing was spent yet or the ledger table is missing.
      def self.spend(model)
        return unless Records::BackfillSpend.available?

        Records::BackfillSpend.for_model(model).find_by(vocabulary_version: ledger_version(model))
      end

      # Zeroes the current vocabulary version's ledger in place, so a chain
      # still running keeps its row and continues against the fresh total.
      def self.reset_spend!(model)
        return unless Records::BackfillSpend.available?

        Records::BackfillSpend.for_model(model).where(vocabulary_version: ledger_version(model))
          .update_all(spent_usd: 0.0, requests: 0, updated_at: Time.current)
      end

      def self.ledger_version(model)
        model.truffler_definition.vocabulary.version(all_users: true)
      end

      # Seconds to wait after `denials` consecutive budget denials with no
      # work in between: 1, 2, 4, ... capped at MAX_BACKOFF, or the budget's
      # retry hint when that is longer.
      def self.backoff(denials, retry_after = nil)
        [ [ INITIAL_BACKOFF * (2**denials), MAX_BACKOFF ].min, retry_after.to_f ].max
      end

      attr_reader :model, :batch_size, :page_size

      def initialize(model, spend_cap: Truffler.config.backfill_spend_cap, batch_size: Truffler.config.batch_size,
        page_size: nil, cursor: nil, spent: 0.0, client: Truffler.config.client, budget: Budget.new)
        @model = model
        model.truffler_definition.validate_columns!
        @batch_size = batch_size
        @page_size = page_size || batch_size * 5
        @cursor = cursor
        @spend_cap = spend_cap
        @spent = spent
        @client = client
        @budget = budget
        @versions = {}
      end

      # `progress` is called with the result so far and the delay before each
      # wait; it carries counts, cost, and the cursor, never record text.
      def run(max_pages: nil, wait: false, max_duration: nil, sleeper: self.class.sleeper, clock: self.class.clock,
        progress: nil)
        @labeled = 0
        @started_cost = meter.cost
        @pages = 0
        deadline = max_duration && clock.call + max_duration
        denials = 0

        loop do
          before = [ @labeled, meter.requests ]
          status = sweep(max_pages, deadline, clock)
          return result(status) unless wait && status == :budget_denied

          denials = 0 unless before == [ @labeled, meter.requests ]
          delay = self.class.backoff(denials, @retry_after)
          return result(:paused) if deadline && clock.call + delay > deadline

          progress&.call(result(status), delay)
          sleeper.call(delay)
          denials += 1
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

      # Spend carried in with `spent:` is ignored when the ledger holds it.
      def meter
        @meter ||= begin
          ledger = Records::BackfillSpend.ledger(model, version_for(nil)) if Records::BackfillSpend.available?
          SpendMeter.new(@client, cap: @spend_cap, spent: ledger ? 0.0 : @spent, ledger: ledger)
        end
      end

      def version_for(tenant_key)
        @versions[tenant_key] ||= definition.vocabulary.version(tenant_key: tenant_key, all_users: true)
      end

      def result(status)
        Result.new(status: status, labeled: @labeled, requests: meter.requests, cost: meter.cost - @started_cost,
          cursor: @cursor, retry_after: (@retry_after if status == :budget_denied))
      end

      # Walks pages below @cursor until done or stopped, returning the status.
      def sweep(max_pages, deadline, clock)
        @retry_after = nil
        loop do
          scanned, rows = page(@cursor)
          return complete if scanned.empty?
          return :paused if (max_pages && @pages >= max_pages) || (deadline && clock.call >= deadline)

          rows.group_by(&:last).each do |tenant_key, tenant_rows|
            tenant_rows.map(&:first).each_slice(batch_size) do |ids|
              stop = label(ids, tenant_key)
              return stop if stop
            end
          end

          @cursor = scanned.last
          @pages += 1
          return complete if scanned.size < page_size
        end
      end

      def complete
        @cursor = nil
        :complete
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
          Labeler.new(model, client: meter, budget: @budget).label(claimed, priority: :backfill)
        rescue SpendCapReached
          queue.demote(claimed)
          return :spend_cap_reached
        rescue BudgetExhausted => error
          queue.demote(claimed)
          @retry_after = error.retry_after
          return :budget_denied
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
