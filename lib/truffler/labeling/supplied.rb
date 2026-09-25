module Truffler
  module Labeling
    # Writes host-supplied labels (`label ..., from:`) straight from records
    # of one tenant into truffler_labels, under the same storage keys as asked
    # labels, and rewrites those records' label vectors. No Jev request, no
    # budget slot, no spend. A nil answer stores nothing, so the label reads
    # as missing rather than 0. Both failures are instrumented as
    # `supplied_label_failed`. An answer out of shape (InvalidSuppliedAnswer)
    # is permanent (`permanent: true`): it stores nothing for that label,
    # like a nil answer, and the record settles, since retrying the same
    # answer cannot succeed. A `from` that raises anything else is transient:
    # the label is skipped and listed in `failed_ids` so the caller retries
    # it (failed after max_attempts); its stored rows serve meanwhile.
    class Supplied
      attr_reader :model, :failed_ids

      def initialize(model)
        @model = model
        model.truffler_definition.validate_columns!
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
      rescue InvalidSuppliedAnswer => error
        instrument_failure(label, record, tenant_key, error, permanent: true)
        nil
      rescue StandardError => error
        instrument_failure(label, record, tenant_key, error, permanent: false)
        :failed
      end

      def instrument_failure(label, record, tenant_key, error, permanent:)
        Instrumentation.instrument(:supplied_label_failed, record_type: record_type, tenant_key: tenant_key, record_id: record.id,
          label_key: label.key, error_class: error.class.name, permanent: permanent)
      end
    end
  end
end
