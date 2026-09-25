module Truffler
  module Embeddings
    # Cosine distance computed by the database: pgvector's `<=>` on a vector
    # column, or sqlite-vec's `vec_distance_cosine` on float32 blobs (the
    # host loads the extension). Because similarity is plain SQL, search can
    # score text inline in its one query as an exact scan of the tenant's
    # rows; an approximate (HNSW) index is an opt-in host migration.
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

      def initialize(dialect: nil)
        @dialect = dialect
      end

      def nearest(model, tenant_key:, vector:, k: DEFAULT_K)
        distance = distance_sql(model, "#{TABLE}.embedding", vector)
        embeddings(model, tenant_key, vector.size).order(Arel.sql(distance)).limit(k)
          .pluck(:record_id, Arel.sql("1 - #{distance}")).map { |id, similarity| [ id, similarity.to_f ] }
      end

      def similarity_sql(model, tenant_key:, vector:, k: nil)
        similarity = "1 - #{distance_sql(model, "#{TABLE}.embedding", vector)}"
        subquery = embeddings(model, tenant_key, vector.size).where("#{TABLE}.record_id = #{primary_key_sql(model)}")
        Arel.sql("COALESCE((#{subquery.select(Arel.sql(similarity)).to_sql}), 0.0)")
      end

      def inline_sql?(_model)
        true
      end

      private

      def distance_sql(model, column_sql, vector)
        @dialect ||= self.class.dialect(model.connection)
        self.class.distance_sql(@dialect, model.connection, column_sql, vector)
      end
    end
  end
end
