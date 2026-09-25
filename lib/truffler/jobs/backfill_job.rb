module Truffler
  module Jobs
    # Backfills one model's stale, missing, failed, and demoted labels at
    # backfill priority. Arguments are the record type, the id cursor, the
    # spend so far, the cap, the retry attempt, and the count of budget
    # denials in a row, never record text. A budget denial reschedules the job
    # from its cursor after the same backoff a waiting Labeling::Backfill uses
    # (reset whenever a run lands work); a page limit reschedules it at once;
    # the spend cap ends it. A Jev error reschedules it with backoff and the spend
    # already made, so retries cannot push past the cap; after MAX_ATTEMPTS
    # the released rows wait for the ResumeJob sweep.
    class BackfillJob < ActiveJob::Base
      MAX_PAGES = 20
      MAX_ATTEMPTS = 10

      queue_as { Truffler.config.queue_name }

      def perform(record_type, cursor: nil, spent: 0.0, spend_cap: Truffler.config.backfill_spend_cap, max_pages: MAX_PAGES,
        attempt: 0, denials: 0)
        model = record_type.safe_constantize
        return unless model.respond_to?(:truffler_definition) && model.truffler_definition

        result = Labeling::Backfill.new(model, cursor: cursor, spent: spent, spend_cap: spend_cap).run(max_pages: max_pages)
        Instrumentation.instrument(:backfill, record_type: record_type, outcome: result.status,
          labeled_count: result.labeled, request_count: result.requests, cost: result.cost)

        follow_up = { cursor: result.cursor, spent: spent + result.cost, spend_cap: spend_cap, max_pages: max_pages }
        case result.status
        when :budget_denied then retry_after_denial(record_type, follow_up, result, denials)
        when :paused then self.class.perform_later(record_type, **follow_up)
        when :client_error then retry_later(record_type, follow_up, attempt + 1)
        when :complete, :spend_cap_reached then nil
        else raise ArgumentError, "unknown backfill status #{result.status.inspect}"
        end
      end

      private

      def retry_after_denial(record_type, follow_up, result, denials)
        denials = 0 if result.labeled.positive? || result.requests.positive?
        wait = Labeling::Backfill.backoff(denials, result.retry_after)
        self.class.set(wait: wait).perform_later(record_type, **follow_up, denials: denials + 1)
      end

      def retry_later(record_type, follow_up, attempt)
        return if attempt >= MAX_ATTEMPTS

        self.class.set(wait: (attempt**4) + 2).perform_later(record_type, **follow_up, attempt: attempt)
      end
    end
  end
end
