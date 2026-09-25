module Truffler
  module Embeddings
    # Packed float blobs in truffler_embeddings with exact cosine computed in
    # Ruby over the tenant's rows. For tests and small sets.
    class RubyStore < VectorStore
      def nearest(model, tenant_key:, vector:, k: DEFAULT_K)
        rows = embeddings(model, tenant_key, vector.size).pluck(:record_id, :embedding)
        rows.map { |id, blob| [ id, self.class.cosine(vector, Records::Embedding.unpack(blob)) ] }.max_by(k) { |_, similarity| similarity }
      end
    end
  end
end
