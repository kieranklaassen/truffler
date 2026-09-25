module Truffler
  module Jobs
    # Backfills one model's stale, missing, failed, and demoted labels at
    # backfill priority. Arguments are the record type, the id cursor, the
    # spend so far, the cap, and the retry attempt, never record text. A
    # budget denial or a page limit reschedules the job from its cursor; the
    # spend cap ends it. A Jev error reschedules it with backoff and the spend
    # already made, so retries cannot push past the cap; after MAX_ATTEMPTS
    # the released rows wait for the ResumeJob sweep.
    class BackfillJob < ActiveJob::Base
      MAX_PAGES = 20
      MAX_ATTEMPTS = 10
      BUDGET_WAIT = 30.seconds

      queue_as { Truffler.config.queue_name }

      def perform(record_type, cursor: nil, spent: 0.0, spend_cap: Truffler.config.backfill_spend_cap, max_pages: MAX_PAGES,
        attempt: 0)
        model = record_type.safe_constantize
        return unless model.respond_to?(:truffler_definition) && model.truffler_definition

        result = Labeling::Backfill.new(model, cursor: cursor, spent: spent, spend_cap: spend_cap).run(max_pages: max_pages)
        Instrumentation.instrument(:backfill, record_type: record_type, outcome: result.status,
          labeled_count: result.labeled, request_count: result.requests, cost: result.cost)

        follow_up = { cursor: result.cursor, spent: spent + result.cost, spend_cap: spend_cap, max_pages: max_pages }
        case result.status
        when :budget_denied then self.class.set(wait: BUDGET_WAIT).perform_later(record_type, **follow_up)
        when :paused then self.class.perform_later(record_type, **follow_up)
        when :client_error then retry_later(record_type, follow_up, attempt + 1)
        when :complete, :spend_cap_reached then nil
        else raise ArgumentError, "unknown backfill status #{result.status.inspect}"
        end
      end

      private

      def retry_later(record_type, follow_up, attempt)
        return if attempt >= MAX_ATTEMPTS

        self.class.set(wait: (attempt**4) + 2).perform_later(record_type, **follow_up, attempt: attempt)
      end
    end
  end
end
