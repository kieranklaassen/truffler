module Truffler
  module Embeddings
    # A record's labels as a named-dimension vector (KTD20): one float per
    # storage key in sorted order, choice options expanded, stored in
    # truffler_embeddings beside the optional text vector and tagged with the
    # vocabulary version that fixed the key order. Unlabeled keys are 0.0.
    # Vectors are built from truffler_labels only, so a vocabulary change
    # rebuilds them without asking Jev. Lens labels in the record's labeling
    # scope (KTD21) extend the vector after the declared ones.
    class LabelVector
      attr_reader :model

      def initialize(model)
        @model = model
      end

      def keys(tenant_key = nil)
        vocabulary.labels_for(tenant_key: tenant_key, all_users: true).values.flat_map { |label| label.storage_keys(tenant_key) }.sort
      end

      def write(record_ids, tenant_key:)
        return 0 if record_ids.empty?

        keys = keys(tenant_key)
        version = version_for(tenant_key)
        values = Records::Label.where(record_type: record_type, record_id: record_ids, label_key: keys)
          .pluck(:record_id, :label_key, :value)
          .each_with_object(Hash.new { |hash, id| hash[id] = {} }) { |(id, key, value), map| map[id.to_s][key] = value }
        now = Time.current
        rows = record_ids.uniq.map do |id|
          vector = keys.map { |key| values[id.to_s].fetch(key, 0.0) }
          { record_type: record_type, record_id: id, tenant_key: tenant_key, label_vector: Records::Embedding.pack(vector),
            label_vocabulary_version: version, created_at: now, updated_at: now }
        end
        Records::Embedding.upsert_all(rows, unique_by: %i[record_type record_id],
          update_only: %i[tenant_key label_vector label_vocabulary_version])
        rows.size
      end

      # Rewrites every vector whose vocabulary version is not current, for
      # one tenant or all of them. Returns the number of records rewritten.
      def rebuild(tenant_key: :all, batch_size: 500)
        tenants = tenant_key == :all ? Records::Label.where(record_type: record_type).distinct.pluck(:tenant_key) : [ tenant_key ]
        tenants.sum do |tenant|
          version = version_for(tenant)
          current = Records::Embedding.for_model(model).where(tenant_key: tenant, label_vocabulary_version: version).select(:record_id)
          ids = Records::Label.where(record_type: record_type, tenant_key: tenant).where.not(record_id: current).distinct.pluck(:record_id)
          ids.each_slice(batch_size).sum { |slice| write(slice, tenant_key: tenant) }
        end
      end

      # The stored vector keyed by label, or nil when it is missing or was
      # written under another vocabulary version.
      def read(record)
        tenant_key = definition.tenant_key_for(record)
        row = Records::Embedding.for_model(model).find_by(record_id: record.id)
        return unless row&.label_vector && row.label_vocabulary_version == version_for(tenant_key)

        keys(tenant_key).zip(row.label_values).to_h
      end

      private

      def definition
        model.truffler_definition
      end

      def vocabulary
        definition.vocabulary
      end

      def version_for(tenant_key)
        vocabulary.version(tenant_key: tenant_key, all_users: true)
      end

      def record_type
        model.polymorphic_name
      end
    end
  end
end
