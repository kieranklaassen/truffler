module Truffler
  module Jobs
    # A periodic sweep hosts schedule (every few minutes) so labeling resumes
    # after a Jev outage or a crashed worker. It returns failed rows and rows
    # stuck in labeling to pending, reschedules a flush for tenants whose live
    # rows have waited past `resume_pending_after`, and starts a BackfillJob
    # per tenant with rows waiting at backfill priority. Disabled tenants
    # (config.tenant_enabled) get neither. For models with gem-managed
    # embeddings it also enqueues up to `embedding_sweep_limit` missing or
    # stale embeddings, tenant by tenant for scoped models, at most once per
    # `embedding_sweep_interval`, so an embedder outage cannot pile duplicate
    # jobs onto the queue. Pass a record type to sweep one model.
    class ResumeJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      class_attribute :embedding_sweep_limit, default: 1_000
      class_attribute :embedding_sweep_interval, default: 1.hour

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

        definition = model.truffler_definition
        live = (requeued.select { |_, priority| priority == "live" }.map(&:first) +
          waiting.where(priority: "live").distinct.pluck(:tenant_key)).uniq.select { |key| definition.tenant_enabled?(key) }
        queue = Labeling::Queue.new(model)
        live.each do |tenant_key|
          queue.clear_marker(tenant_key)
          queue.schedule(tenant_key)
        end

        backfill = (requeued.select { |_, priority| priority == "backfill" }.map(&:first) +
          waiting.where(priority: "backfill").distinct.pluck(:tenant_key)).uniq
        backfill.select { |key| definition.tenant_enabled?(key) }.each do |tenant_key|
          BackfillJob.perform_later(model.polymorphic_name, **BackfillJob.tenant_argument(model, tenant_key))
        end
        sweep_embeddings(model)
      end

      def sweep_embeddings(model)
        return unless Embeddings.managed?(model.truffler_definition)

        marker = "truffler:embedding_sweep:#{model.polymorphic_name}"
        return unless Truffler.config.cache_store.write(marker, true, unless_exist: true, expires_in: embedding_sweep_interval)

        backfill = Embeddings::Backfill.new(model)
        return backfill.enqueue(limit: embedding_sweep_limit) unless model.truffler_definition.scoped?

        remaining = embedding_sweep_limit
        backfill.tenant_keys.each do |tenant_key|
          break unless remaining.positive?

          remaining -= backfill.enqueue(limit: remaining, tenant_key: tenant_key)
        end
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
