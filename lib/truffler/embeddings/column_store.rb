module Truffler
  module Embeddings
    # Searches a vector column the host already maintains (R11). The gem never
    # writes it and never calls the embedder for it. Similarity runs in SQL
    # when the column is pgvector or sqlite-vec is loaded, and otherwise as
    # exact cosine in Ruby over the tenant's rows (arrays, JSON text, or
    # float32 blobs).
    class ColumnStore < VectorStore
      attr_reader :column

      def initialize(column)
        @column = column.to_s
      end

      def write(model, *)
        raise Error, "#{model.name} searches its own #{column} column; truffler does not write it"
      end

      def nearest(model, tenant_key:, vector:, k: DEFAULT_K)
        scope = records(model, tenant_key)
        if (dialect = dialect(model))
          distance = NeighborStore.distance_sql(dialect, model.connection, column_sql(model), vector)
          scope.order(Arel.sql(distance)).limit(k).pluck(model.primary_key, Arel.sql("1 - #{distance}"))
            .map { |id, similarity| [ id, similarity.to_f ] }
        else
          scope.pluck(model.primary_key, column).filter_map do |id, value|
            stored = Records::Embedding.unpack(value)
            [ id, self.class.cosine(vector, stored) ] if stored.size == vector.size
          end.max_by(k) { |_, similarity| similarity }
        end
      end

      def similarity_sql(model, tenant_key:, vector:, k: DEFAULT_K)
        dialect = dialect(model)
        return super unless dialect

        check_tenant!(model, tenant_key)
        Arel.sql("COALESCE(1 - #{NeighborStore.distance_sql(dialect, model.connection, column_sql(model), vector)}, 0.0)")
      end

      def inline_sql?(model)
        !dialect(model).nil?
      end

      private

      def records(model, tenant_key)
        check_tenant!(model, tenant_key)
        definition = model.truffler_definition
        scope = model.where.not(column => nil)
        definition.scoped? ? scope.where(definition.tenant_column => tenant_key) : scope
      end

      def dialect(model)
        return @dialect if defined?(@dialect)

        @dialect = NeighborStore.dialect(model.connection, table: model.table_name, column: column)
      end

      def column_sql(model)
        "#{model.connection.quote_table_name(model.table_name)}.#{model.connection.quote_column_name(column)}"
      end
    end
  end
end
