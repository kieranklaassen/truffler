require "ruby_llm"

module Truffler
  module Embeddings
    # The default embedder: `RubyLLM.embed`, which ruby_llm 1.x and 2 share.
    # ruby_llm is not a truffler dependency; this file loads only when the
    # default embedder is used.
    class RubyLLMEmbedder < Embedder
      def perform(texts, model:, dimensions:)
        embedding = RubyLLM.embed(texts, model: model, dimensions: dimensions)
        vectors = embedding.vectors
        vectors = [ vectors ] if vectors.first.is_a?(Numeric)
        { vectors: vectors, model: embedding.model, input_tokens: input_tokens(embedding) }
      end

      private

      def input_tokens(embedding)
        return embedding.input_tokens if embedding.respond_to?(:input_tokens)

        embedding.tokens&.input if embedding.respond_to?(:tokens)
      end
    end
  end
end
