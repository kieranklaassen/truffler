module Truffler
  module Labeling
    # Relabels one model's records whose labels are missing, stale (labeled
    # under another vocabulary version), failed, or demoted to backfill
    # priority. It walks newest-first below an id cursor over the
    # definition's index_scope (one tenant's records with `tenant_key:`),
    # splits each page by tenant, skips disabled tenants, packs batch_size
    # records per request at backfill priority, and asks only the stale
    # questions. Live pending rows belong to the flush job and are never
    # touched.
    #
    # Resumable: the cursor moves past a page only once the whole page is
    # done, and records already current are skipped, so a rerun never asks
    # Jev about them again. A spend cap stops the run before a request would
    # exceed it; host-supplied labels cost nothing, so they are still written
    # once the cap is reached. The cap counts everything spent under the
    # current vocabulary version in the truffler_backfill_spends ledger, so
    # reruns and overlapping jobs share it. Tenant-scoped models keep one
    # ledger per tenant (backfill_spend_cap_scope :tenant, the default), so
    # the cap applies to each tenant: a whole-model run skips a tenant at its
    # cap, keeps labeling the others, and ends with `:spend_cap_reached`; a
    # tenant run stops there. Unscoped models, and :app, keep one app-wide
    # ledger. Without that table the cap falls back to this run plus
    # `spent:`. A Jev error releases the claimed rows and ends the run with
    # `:client_error`, so the caller keeps the spend metered so far.
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

      def self.status(model, tenant_key: nil)
        new(model, tenant_key: tenant_key).status
      end

      # The ledger row for the current vocabulary version (the tenant's, for
      # a tenant ledger), or nil when nothing was spent yet or the ledger
      # table is missing.
      def self.spend(model, tenant_key: nil)
        return unless Records::BackfillSpend.available?

        Records::BackfillSpend.for_ledger(model, tenant_key).find_by(vocabulary_version: ledger_version(model, tenant_key))
      end

      # Zeroes the current vocabulary version's ledger in place, so a chain
      # still running keeps its row and continues against the fresh total.
      # `all_tenants: true` zeroes every tenant ledger of the model.
      def self.reset_spend!(model, tenant_key: nil, all_tenants: false)
        return unless Records::BackfillSpend.available?

        ledgers = if all_tenants && Records::BackfillSpend.tenant_ledgers?
          Records::BackfillSpend.for_model(model).where.not(tenant_key: nil)
        else
          Records::BackfillSpend.for_ledger(model, tenant_key).where(vocabulary_version: ledger_version(model, tenant_key))
        end
        ledgers.update_all(spent_usd: 0.0, requests: 0, updated_at: Time.current)
      end

      def self.ledger_version(model, tenant_key = nil)
        model.truffler_definition.vocabulary.version(tenant_key: tenant_key, all_users: true)
      end

      # Seconds to wait after `denials` consecutive budget denials with no
      # work in between: 1, 2, 4, ... capped at MAX_BACKOFF, or the budget's
      # retry hint when that is longer.
      def self.backoff(denials, retry_after = nil)
        [ [ INITIAL_BACKOFF * (2**denials), MAX_BACKOFF ].min, retry_after.to_f ].max
      end

      attr_reader :model, :batch_size, :page_size

      def initialize(model, tenant_key: nil, spend_cap: Truffler.config.backfill_spend_cap, batch_size: Truffler.config.batch_size,
        page_size: nil, cursor: nil, spent: 0.0, client: Truffler.config.client, budget: Budget.new)
        @model = model
        @tenant_key = tenant_key&.to_s if model.truffler_definition.scoped?
        model.truffler_definition.validate_columns!
        @batch_size = batch_size
        @page_size = page_size || batch_size * 5
        @cursor = cursor
        @spend_cap = spend_cap
        @spent = spent
        @client = client
        @budget = budget
        @versions = {}
        @meters = {}
        @enabled = {}
        @capped = Set.new
      end

      # `progress` is called with the result so far and the delay before each
      # wait; it carries counts, cost, and the cursor, never record text.
      def run(max_pages: nil, wait: false, max_duration: nil, sleeper: self.class.sleeper, clock: self.class.clock,
        progress: nil)
        @labeled = 0
        @started_cost = spent_cost
        @pages = 0
        deadline = max_duration && clock.call + max_duration
        denials = 0

        loop do
          before = [ @labeled, requests ]
          status = sweep(max_pages, deadline, clock)
          return result(status) unless wait && status == :budget_denied

          denials = 0 unless before == [ @labeled, requests ]
          delay = self.class.backoff(denials, @retry_after)
          return result(:paused) if deadline && clock.call + delay > deadline

          progress&.call(result(status), delay)
          sleeper.call(delay)
          denials += 1
        end
      end

      # Counts over what the backfill may touch: index_scope, enabled tenants,
      # and the one tenant when `tenant_key:` is given.
      def status
        scope, tenants = status_scope
        tracked = states.where(record_id: scope.select(model.arel_table[model.primary_key]))
        tracked = tracked.where(tenant_key: tenants) if tenants
        counts = tracked.group(:status).count
        labeled = tracked.where(status: "labeled").group(:tenant_key, :vocabulary_version).count
        stale = labeled.sum { |(tenant_key, version), count| version == version_for(tenant_key) ? 0 : count }
        { total: scope.count, missing: scope.joins(state_join).where("#{STATES}.id IS NULL").count,
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

      # [relation, tenant keys or nil]: the records status counts, and the
      # tenants it covers when it narrows to some.
      def status_scope
        scope = definition.index_relation(model.all)
        return [ scope, nil ] unless definition.scoped?
        return [ scope.where(definition.tenant_column => @tenant_key), [ @tenant_key ] ] if @tenant_key
        return [ scope, nil ] unless Truffler.config.tenant_enabled

        tenants = scope.distinct.pluck(definition.tenant_column).map(&:to_s).select { |tenant_key| enabled?(tenant_key) }
        [ scope.where(definition.tenant_column => tenants), tenants ]
      end

      def queue
        @queue ||= Queue.new(model)
      end

      # One meter per ledger: per tenant for tenant ledgers, else one for the
      # run. Spend carried in with `spent:` is ignored when the ledger holds it.
      def meter(tenant_key)
        ledger_tenant = ledger_available? ? definition.ledger_tenant(tenant_key) : nil
        @meters[ledger_tenant] ||= begin
          ledger = Records::BackfillSpend.ledger(model, version_for(ledger_tenant), tenant_key: ledger_tenant) if ledger_available?
          SpendMeter.new(@client, cap: @spend_cap, spent: ledger ? 0.0 : @spent, ledger: ledger)
        end
      end

      def ledger_available?
        return @ledger_available if defined?(@ledger_available)

        @ledger_available = Records::BackfillSpend.available?
      end

      def requests
        @meters.each_value.sum(&:requests)
      end

      def spent_cost
        @meters.each_value.sum(&:cost)
      end

      def version_for(tenant_key)
        @versions[tenant_key] ||= definition.vocabulary.version(tenant_key: tenant_key, all_users: true)
      end

      def enabled?(tenant_key)
        @enabled.fetch(tenant_key) { @enabled[tenant_key] = definition.tenant_enabled?(tenant_key) }
      end

      def result(status)
        Result.new(status: status, labeled: @labeled, requests: requests, cost: spent_cost - @started_cost,
          cursor: @cursor, retry_after: (@retry_after if status == :budget_denied))
      end

      # Walks pages below @cursor until done or stopped, returning the status.
      def sweep(max_pages, deadline, clock)
        @retry_after = nil
        return complete if @tenant_key && !enabled?(@tenant_key)

        loop do
          scanned, rows = page(@cursor)
          return complete if scanned.empty?
          return :paused if (max_pages && @pages >= max_pages) || (deadline && clock.call >= deadline)

          rows.group_by(&:last).each do |tenant_key, tenant_rows|
            tenant_rows.map(&:first).each_slice(batch_size) do |ids|
              break if @capped.include?(tenant_key)

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
        @capped.any? ? :spend_cap_reached : :complete
      end

      # Returns the scanned ids (for the cursor) and the [id, tenant_key] rows
      # that still need labels. Per-tenant vocabularies (per-tenant choices or
      # lenses) compare versions here because each tenant has its own.
      def page(cursor)
        pk = model.primary_key
        scope = definition.index_relation(model.joins(state_join).where(needs_labeling_sql))
        scope = scope.where(definition.tenant_column => @tenant_key) if @tenant_key
        scope = scope.where(model.arel_table[pk].lt(cursor)) if cursor
        tenant = definition.scoped? ? model.arel_table[definition.tenant_column] : Arel.sql("NULL")
        plucked = scope.reorder(pk => :desc).limit(page_size)
          .pluck(model.arel_table[pk], tenant, Arel.sql("#{STATES}.status"), Arel.sql("#{STATES}.vocabulary_version"))

        rows = plucked.filter_map do |id, tenant_key, status, version|
          tenant_key = tenant_key&.to_s
          [ id, tenant_key ] unless (status == "labeled" && version == version_for(tenant_key)) || !enabled?(tenant_key)
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
      # at backfill priority. A tenant ledger at its cap only stops that
      # tenant in a whole-model run.
      def label(ids, tenant_key)
        claimed = queue.claim_backfill(ids, tenant_key)
        return if claimed.empty?

        begin
          Labeler.new(model, client: meter(tenant_key), budget: @budget).label(claimed, priority: :backfill)
        rescue SpendCapReached
          queue.demote(claimed)
          return :spend_cap_reached if @tenant_key || definition.ledger_tenant(tenant_key).nil? || !ledger_available?

          @capped << tenant_key
          return
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
