module Truffler
  module Labeling
    # Writes host-supplied labels (`label ..., from:`) straight from records
    # of one tenant into truffler_labels, under the same storage keys as asked
    # labels, and rewrites those records' label vectors. No Jev request, no
    # budget slot, no spend. A nil answer stores nothing, so the label reads
    # as missing rather than 0. A `from` that raises or answers out of shape
    # is instrumented as `supplied_label_failed`, skipped, and listed in
    # `failed_ids` so the caller can retry it; its stored rows serve meanwhile.
    class Supplied
      attr_reader :model, :failed_ids

      def initialize(model)
        @model = model
        @failed_ids = Set.new
      end

      # pending: [[record, label_keys], ...]. Returns the ids written.
      def write(pending, tenant_key:)
        now = Time.current
        written = []
        rows = []
        pending.each do |record, keys|
          keys.each do |key|
            label = definition.label(key)
            values = answer(label, record, tenant_key)
            if values == :failed
              failed_ids << record.id
              next
            end

            written << [ record.id, key ]
            fingerprint = label.supplied_fingerprint(tenant_key)
            rows.concat(values.to_h.map do |label_key, value|
              { record_type: record_type, record_id: record.id, tenant_key: tenant_key, label_key: label_key, value: value,
                fingerprint: fingerprint, labeled_at: now }
            end)
          end
        end
        return [] if written.empty?

        ids = written.map(&:first).uniq
        Records::Label.transaction do
          written.each { |id, key| Records::Label.where(record_type: record_type, record_id: id).for_label(key).delete_all }
          Records::Label.insert_all!(rows) if rows.any?
          Embeddings::LabelVector.new(model).write(ids, tenant_key: tenant_key)
        end
        ids
      end

      private

      def definition
        model.truffler_definition
      end

      def record_type
        model.polymorphic_name
      end

      def answer(label, record, tenant_key)
        label.supplied_values(record, tenant_key)
      rescue StandardError => error
        Instrumentation.instrument(:supplied_label_failed, record_type: record_type, tenant_key: tenant_key, record_id: record.id,
          label_key: label.key, error_class: error.class.name)
        :failed
      end
    end
  end
end
