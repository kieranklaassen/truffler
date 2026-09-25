module Truffler
  module Records
    # One row per record holding its optional text vector and its label vector
    # (KTD20). Neither column holds anything derived from text except floats.
    # Blobs are packed little-endian float32, the layout sqlite-vec reads.
    class Embedding < ActiveRecord::Base
      self.table_name = "truffler_embeddings"

      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }
      scope :with_vector, -> { where.not(embedding: nil) }

      def self.pack(vector)
        vector.map(&:to_f).pack("e*")
      end

      def self.unpack(value)
        case value
        when nil then nil
        when Array then value.map(&:to_f)
        else value.encoding == Encoding::BINARY ? value.unpack("e*") : JSON.parse(value).map(&:to_f)
        end
      end

      # The stored form for the `embedding` column: a blob, or pgvector's text
      # literal when the install generator wrote a vector column.
      def self.encode(vector)
        columns_hash["embedding"].type == :binary ? pack(vector) : "[#{vector.map(&:to_f).join(',')}]"
      end

      def vector
        self.class.unpack(embedding)
      end

      def label_values
        self.class.unpack(label_vector)
      end
    end
  end
end
