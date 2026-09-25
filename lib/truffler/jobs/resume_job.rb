module Truffler
  module Jobs
    # A periodic sweep hosts schedule (every few minutes) so labeling resumes
    # after a Jev outage or a crashed worker. It returns failed rows and rows
    # stuck in labeling to pending, reschedules a flush for tenants whose live
    # rows have waited past `resume_pending_after`, and starts a backfill for
    # rows waiting at backfill priority. Pass a record type to sweep one model.
    class ResumeJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform(record_type = nil)
        models = record_type ? [ record_type.safe_constantize ].compact : Truffler.registry.models
        models.select { |model| model.respond_to?(:truffler_definition) && model.truffler_definition }.each { |model| sweep(model) }
      end

      private

      def sweep(model)
        states = Records::RecordState.for_model(model)
        cutoff = Time.current - Truffler.config.resume_pending_after
        requeued = requeue(states.where(status: "failed").or(states.where(status: "labeling").where(claimed_at: ...cutoff)))
        waiting = states.where(status: "pending").where(updated_at: ...cutoff)

        live = (requeued.select { |_, priority| priority == "live" }.map(&:first) +
          waiting.where(priority: "live").distinct.pluck(:tenant_key)).uniq
        queue = Labeling::Queue.new(model)
        live.each do |tenant_key|
          queue.clear_marker(tenant_key)
          queue.schedule(tenant_key)
        end

        backfill = requeued.any? { |_, priority| priority == "backfill" } || waiting.exists?(priority: "backfill")
        BackfillJob.perform_later(model.polymorphic_name) if backfill
      end

      # Returns the distinct [tenant_key, priority] pairs it moved to pending.
      def requeue(scope)
        pairs = scope.distinct.pluck(:tenant_key, :priority)
        scope.update_all(status: "pending", attempts: 0, claimed_at: nil, updated_at: Time.current) if pairs.any?
        pairs
      end
    end
  end
end
