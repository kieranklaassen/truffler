module Truffler
  module Embeddings
    # Cosine distance computed by the database: pgvector's `<=>` on a vector
    # column, or sqlite-vec's `vec_distance_cosine` on float32 blobs (the
    # host loads the extension).
    #
    # On Postgres, search reads text similarity from the tenant's top `k`
    # neighbors (`neighbors_sql`, one `ORDER BY embedding <=> q LIMIT k`
    # that an HNSW index can serve), so records outside the top K score no
    # text similarity. Pass `top_k: false` for an exact inline similarity per
    # row, the sqlite-vec default; `top_k: true` uses the join there too.
    class NeighborStore < VectorStore
      TABLE = "truffler_embeddings".freeze

      def self.available?(connection, table: TABLE, column: "embedding")
        !dialect(connection, table: table, column: column).nil?
      end

      def self.dialect(connection, table: TABLE, column: "embedding")
        case connection.adapter_name
        when /postg/i
          :postgres if connection.columns(table).find { |item| item.name == column.to_s }&.sql_type.to_s.start_with?("vector")
        when /sqlite/i
          :sqlite if sqlite_vec?(connection)
        end
      end

      def self.sqlite_vec?(connection)
        connection.select_value("SELECT vec_version()").present?
      rescue ActiveRecord::StatementInvalid
        false
      end

      def self.distance_sql(dialect, connection, column_sql, vector)
        case dialect
        when :sqlite then "vec_distance_cosine(#{column_sql}, X'#{Records::Embedding.pack(vector).unpack1('H*')}')"
        when :postgres then "(#{column_sql} <=> #{connection.quote("[#{vector.map(&:to_f).join(',')}]")}::vector)"
        else raise Error, "the neighbor vector store needs pgvector or the sqlite-vec extension"
        end
      end

      attr_reader :k

      def initialize(dialect: nil, k: DEFAULT_K, top_k: nil)
        @dialect = dialect
        @k = Integer(k)
        @top_k = top_k
      end

      def nearest(model, tenant_key:, vector:, k: self.k)
        distance = distance_sql(model, "#{TABLE}.embedding", vector)
        embeddings(model, tenant_key, vector.size).order(Arel.sql(distance)).limit(k)
          .pluck(:record_id, Arel.sql("1 - #{distance}")).map { |id, similarity| [ id, similarity.to_f ] }
      end

      # The tenant's `k` nearest vectors as `(record_id, similarity)` rows,
      # for search to LEFT JOIN on record_id; nil when this store scores
      # inline instead.
      def neighbors_sql(model, tenant_key:, vector:, k: self.k)
        return unless top_k?(model)

        distance = distance_sql(model, "#{TABLE}.embedding", vector)
        embeddings(model, tenant_key, vector.size).reorder(Arel.sql(distance)).limit(k)
          .select(Arel.sql("#{TABLE}.record_id AS record_id"), Arel.sql("1 - #{distance} AS similarity")).to_sql
      end

      def similarity_sql(model, tenant_key:, vector:, k: nil)
        similarity = "1 - #{distance_sql(model, "#{TABLE}.embedding", vector)}"
        subquery = embeddings(model, tenant_key, vector.size).where("#{TABLE}.record_id = #{primary_key_sql(model)}")
        Arel.sql("COALESCE((#{subquery.select(Arel.sql(similarity)).to_sql}), 0.0)")
      end

      def inline_sql?(_model)
        true
      end

      def top_k?(model)
        @top_k.nil? ? dialect(model) == :postgres : @top_k
      end

      private

      def dialect(model)
        @dialect ||= self.class.dialect(model.connection)
      end

      def distance_sql(model, column_sql, vector)
        self.class.distance_sql(dialect(model), model.connection, column_sql, vector)
      end
    end
  end
end
