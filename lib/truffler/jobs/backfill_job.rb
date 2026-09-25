module Truffler
  module Jobs
    # Backfills one model's stale, missing, failed, and demoted labels at
    # backfill priority. Arguments are the record type, the id cursor, the
    # spend so far, and the cap, never record text. A budget denial or a page
    # limit reschedules the job from its cursor; the spend cap ends it.
    class BackfillJob < ActiveJob::Base
      RETRYABLE = [ ClientError, IncompleteAnswers ].freeze
      MAX_PAGES = 20
      BUDGET_WAIT = 30.seconds

      queue_as { Truffler.config.queue_name }

      retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 10) { nil }

      def perform(record_type, cursor: nil, spent: 0.0, spend_cap: Truffler.config.backfill_spend_cap, max_pages: MAX_PAGES)
        model = record_type.safe_constantize
        return unless model.respond_to?(:truffler_definition) && model.truffler_definition

        result = Labeling::Backfill.new(model, cursor: cursor, spent: spent, spend_cap: spend_cap).run(max_pages: max_pages)
        Instrumentation.instrument(:backfill, record_type: record_type, outcome: result.status,
          labeled_count: result.labeled, request_count: result.requests, cost: result.cost)

        follow_up = { cursor: result.cursor, spent: spent + result.cost, spend_cap: spend_cap, max_pages: max_pages }
        case result.status
        when :budget_denied then self.class.set(wait: BUDGET_WAIT).perform_later(record_type, **follow_up)
        when :paused then self.class.perform_later(record_type, **follow_up)
        when :complete, :spend_cap_reached then nil
        else raise ArgumentError, "unknown backfill status #{result.status.inspect}"
        end
      end
    end
  end
end
