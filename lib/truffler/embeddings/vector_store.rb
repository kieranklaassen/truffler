module Truffler
  module Embeddings
    # Nearest-neighbor search over one tenant's vectors. `nearest` returns
    # `[record_id, cosine_similarity]` pairs, most similar first.
    # `similarity_sql` returns a scalar SQL expression over the model's table
    # that search can put in its SELECT or ORDER BY: stores that compute
    # similarity in the database (`inline_sql?`) scan every row exactly, and
    # the rest fall back to a CASE over the top-K neighbors.
    class VectorStore
      ADAPTERS = %i[auto ruby neighbor].freeze
      DEFAULT_K = 200

      def self.for(model, config: Truffler.config)
        embeddings = model.truffler_definition.embeddings
        return unless embeddings
        return ColumnStore.new(embeddings[:column]) if embeddings.key?(:column)

        case config.vector_store&.to_sym
        when :ruby then RubyStore.new
        when :neighbor then NeighborStore.new
        when :auto then NeighborStore.available?(model.connection) ? NeighborStore.new : RubyStore.new
        else raise Error, "config.vector_store must be one of #{ADAPTERS.join(', ')}"
        end
      end

      def self.cosine(left, right)
        dot = left_norm = right_norm = 0.0
        left.each_with_index do |value, index|
          other = right[index]
          dot += value * other
          left_norm += value * value
          right_norm += other * other
        end
        left_norm.zero? || right_norm.zero? ? 0.0 : dot / Math.sqrt(left_norm * right_norm)
      end

      def nearest(model, tenant_key:, vector:, k: DEFAULT_K)
        raise NotImplementedError, "#{self.class.name}#nearest"
      end

      def similarity_sql(model, tenant_key:, vector:, k: DEFAULT_K)
        pairs = nearest(model, tenant_key: tenant_key, vector: vector, k: k)
        return Arel.sql("0.0") if pairs.empty?

        connection = model.connection
        whens = pairs.map { |id, similarity| "WHEN #{connection.quote(id)} THEN #{Float(similarity)}" }
        Arel.sql("(CASE #{primary_key_sql(model)} #{whens.join(' ')} ELSE 0.0 END)")
      end

      def inline_sql?(_model)
        false
      end

      def write(model, record, vector, fingerprint:)
        now = Time.current
        Records::Embedding.upsert(
          { record_type: model.polymorphic_name, record_id: record.id, tenant_key: model.truffler_definition.tenant_key_for(record),
            fingerprint: fingerprint, embedding: Records::Embedding.encode(vector), dimensions: vector.size,
            created_at: now, updated_at: now },
          unique_by: %i[record_type record_id],
          update_only: %i[tenant_key fingerprint embedding dimensions updated_at]
        )
      end

      private

      def embeddings(model, tenant_key, dimensions)
        check_tenant!(model, tenant_key)
        Records::Embedding.for_model(model).with_vector.where(tenant_key: tenant_key&.to_s, dimensions: dimensions)
      end

      def check_tenant!(model, tenant_key)
        return unless model.truffler_definition.scoped? && tenant_key.nil?

        raise MissingScope, "#{model.name}: vector search needs a tenant"
      end

      def primary_key_sql(model)
        connection = model.connection
        "#{connection.quote_table_name(model.table_name)}.#{connection.quote_column_name(model.primary_key)}"
      end
    end
  end
end
