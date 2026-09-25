module Truffler
  module Lenses
    # Labels a lens's scope with its active questions (R41, R45): newest
    # records first by arrival, at backfill priority, and only until the
    # lens's spend cap. Records whose lens rows already carry the current
    # fingerprints are skipped, so a rerun resumes where the last one stopped,
    # and values from an earlier version keep serving until relabeled.
    class Backfill
      Result = Data.define(:status, :labeled, :requests, :spent_usd)

      LABELS = Records::Label.table_name

      attr_reader :lens, :batch_size

      def initialize(lens, batch_size: Truffler.config.batch_size, max_batches: nil, client: Truffler.config.client,
        budget: Budget.new)
        @lens = lens
        @batch_size = batch_size
        @max_batches = max_batches
        @client = client
        @budget = budget
      end

      def run
        @labeled = 0
        @meter = nil
        attempted = []
        batches = 0

        loop do
          return result(:inactive) unless lens.reload.active?
          return result(:spend_cap_reached) if lens.spend_cap_reached?
          return result(:paused) if @max_batches && batches >= @max_batches

          records = page(attempted)
          return result(:complete) if records.empty?

          attempted.concat(records.map(&:id))
          records.group_by { |record| definition.tenant_key_for(record) }.each do |tenant_key, slice|
            stop = label(slice, tenant_key)
            return result(stop) if stop
          end
          batches += 1
        end
      end

      private

      def model
        lens.model
      end

      def definition
        model.truffler_definition
      end

      def queue
        @queue ||= Labeling::Queue.new(model)
      end

      def meter
        @meter ||= Labeling::Backfill::SpendMeter.new(@client, cap: lens.spend_cap_usd, spent: lens.spent_usd)
      end

      def result(status)
        Result.new(status: status, labeled: @labeled, requests: @meter&.requests.to_i, spent_usd: lens.reload.spent_usd.to_f)
      end

      # The next batch_size in-scope records, newest first, missing a current
      # lens row.
      def page(attempted)
        pk = model.primary_key
        scope = definition.index_relation(model.all)
        scope = scope.where(definition.tenant_column => lens.tenant_key) if definition.scoped? && lens.tenant_key
        scope = scope.where.not(pk => attempted) if attempted.any?
        scope.where(Arel.sql(stale_sql)).reorder(definition.arrival_order).limit(batch_size).to_a
      end

      # Stale unless every lens label has a row under its current fingerprint;
      # a choice label stores only some of its options.
      def stale_sql
        pk = "#{model.quoted_table_name}.#{model.connection.quote_column_name(model.primary_key)}"
        current = lens.labels.values.map do |label|
          ActiveRecord::Base.sanitize_sql_array([
            "EXISTS (SELECT 1 FROM #{LABELS} WHERE #{LABELS}.record_type = ? AND #{LABELS}.record_id = #{pk} " \
            "AND #{LABELS}.label_key IN (?) AND #{LABELS}.fingerprint = ?)",
            model.polymorphic_name, label.storage_keys, Lenses.fingerprint(label.question)
          ])
        end
        "NOT (#{current.join(' AND ')})"
      end

      # Labels one tenant's records through the labeler, which asks only
      # their stale questions. Returns nil, or the status that stops the run.
      def label(records, tenant_key)
        claimed = queue.claim_backfill(records.map(&:id), tenant_key)
        return if claimed.empty?

        begin
          Labeling::Labeler.new(model, client: meter, budget: @budget).label(claimed, priority: :backfill)
        rescue BudgetExhausted, Labeling::Backfill::SpendCapReached => error
          queue.demote(claimed)
          return error.is_a?(BudgetExhausted) ? :budget_denied : :spend_cap_reached
        rescue ClientError, IncompleteAnswers => error
          queue.release(claimed, error)
          raise
        ensure
          @labeled += Records::RecordState.where(id: claimed.map(&:id), status: "labeled").count
        end
        nil
      end
    end
  end
end
