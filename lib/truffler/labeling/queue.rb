module Truffler
  module Labeling
    # State transitions on truffler_record_states for one model, plus the
    # deduplicated scheduling of LabelFlushJob per tenant. Jobs carry only the
    # record type and tenant key.
    class Queue
      attr_reader :model, :config

      def initialize(model, config: Truffler.config)
        @model = model
        @config = config
      end

      def enqueue(record, priority: :live)
        tenant_key = definition.tenant_key_for(record)
        now = Time.current
        Records::RecordState.upsert(
          { record_type: record_type, record_id: record.id, tenant_key: tenant_key, status: "pending",
            priority: priority.to_s, attempts: 0, created_at: now, updated_at: now },
          unique_by: %i[record_type record_id],
          update_only: %i[tenant_key status priority attempts updated_at]
        )
        schedule(tenant_key)
      end

      def forget(record)
        Records::RecordState.where(record_type: record_type, record_id: record.id).delete_all
        Records::Label.where(record_type: record_type, record_id: record.id).delete_all
        Records::Embedding.where(record_type: record_type, record_id: record.id).delete_all
      end

      def schedule(tenant_key)
        window = config.grouping_window.to_f
        return unless config.cache_store.write(marker(tenant_key), true, unless_exist: true, expires_in: window + 300)

        job = Jobs::LabelFlushJob
        job = job.set(wait: window) if window.positive?
        job.perform_later(record_type, tenant_key)
      end

      def clear_marker(tenant_key)
        config.cache_store.delete(marker(tenant_key))
      end

      def claim(tenant_key, priority:, limit:)
        ids = states.where(tenant_key: tenant_key, status: "pending", priority: priority.to_s).order(:id).limit(limit).pluck(:id)
        return [] if ids.empty?

        now = Time.current
        Records::RecordState.where(id: ids, status: "pending").update_all(status: "labeling", claimed_at: now, updated_at: now)
        Records::RecordState.where(id: ids, status: "labeling", claimed_at: now).order(:id).to_a
      end

      def pending?(tenant_key, priority:)
        states.exists?(tenant_key: tenant_key, status: "pending", priority: priority.to_s)
      end

      def release(claimed, error)
        scope = claimed_scope(claimed)
        set = "attempts = attempts + 1, status = ?, last_error_class = ?, claimed_at = NULL, updated_at = ?"
        scope.where("attempts + 1 >= ?", config.max_attempts).update_all([ set, "failed", error.class.name, Time.current ])
        scope.update_all([ set, "pending", error.class.name, Time.current ])
      end

      def demote(claimed)
        claimed_scope(claimed).update_all(status: "pending", priority: "backfill", claimed_at: nil, updated_at: Time.current)
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

      def claimed_scope(claimed)
        Records::RecordState.where(id: claimed.map(&:id), status: "labeling")
      end

      def marker(tenant_key)
        "truffler/flush/#{record_type}/#{tenant_key}"
      end
    end
  end
end
