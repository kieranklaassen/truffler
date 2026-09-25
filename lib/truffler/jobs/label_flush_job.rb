module Truffler
  module Jobs
    # Labels one tenant's pending live records. Arguments are the record type
    # and tenant key only. On a Jev or budget failure the claimed rows go back
    # to pending (or failed after max_attempts) and the job retries. Rows over
    # the tenant's live cap drop to backfill priority and a delayed backfill
    # is scheduled for them.
    class LabelFlushJob < ActiveJob::Base
      RETRYABLE = [ ClientError, BudgetExhausted, IncompleteAnswers ].freeze

      queue_as { Truffler.config.queue_name }

      retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 10) { nil }

      def perform(record_type, tenant_key)
        model = record_type.safe_constantize
        return unless model.respond_to?(:truffler_definition) && model.truffler_definition

        queue = Labeling::Queue.new(model)
        queue.clear_marker(tenant_key)
        states = queue.claim(tenant_key, priority: :live, limit: Truffler.config.batch_size)
        return if states.empty?

        begin
          result = Labeling::Labeler.new(model).label(states, priority: :live)
        rescue *RETRYABLE => error
          queue.release(states, error)
          raise
        end

        if result.demoted
          queue.demote(states)
          queue.schedule_backfill
        end
        queue.schedule(tenant_key) if queue.pending?(tenant_key, priority: :live)
      end
    end
  end
end
