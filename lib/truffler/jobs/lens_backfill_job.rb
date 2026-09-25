module Truffler
  module Jobs
    # Backfills one lens's scope after it is activated or restored (R41,
    # R45). Its only argument is the lens id. A budget denial or the batch
    # limit reschedules it; the spend cap, expiry, or completion ends it.
    class LensBackfillJob < ActiveJob::Base
      RETRYABLE = [ ClientError, IncompleteAnswers ].freeze
      MAX_BATCHES = 20
      BUDGET_WAIT = 30.seconds

      queue_as { Truffler.config.queue_name }

      retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 10) { nil }

      def perform(lens_id, max_batches: MAX_BATCHES)
        lens = Lenses::Lens.find_by(id: lens_id)
        return unless lens&.active?

        result = Lenses::Backfill.new(lens, max_batches: max_batches).run
        Instrumentation.instrument(:lens_backfill, record_type: lens.record_type, tenant_key: lens.tenant_key, lens_id: lens.id,
          outcome: result.status, labeled_count: result.labeled, request_count: result.requests, cost: result.spent_usd)

        case result.status
        when :budget_denied then self.class.set(wait: BUDGET_WAIT).perform_later(lens_id, max_batches: max_batches)
        when :paused then self.class.perform_later(lens_id, max_batches: max_batches)
        when :complete, :spend_cap_reached, :inactive then nil
        else raise ArgumentError, "unknown lens backfill status #{result.status.inspect}"
        end
        result
      end
    end
  end
end
