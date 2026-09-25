require "digest"

module Truffler
  module Embeddings
    # Deterministic vectors for tests and benchmarks: each token adds a signed
    # unit at a position chosen by its hash, and the sum is normalized, so
    # texts that share words point the same way.
    class FakeEmbedder < Embedder
      attr_reader :calls

      def initialize(model: nil)
        @model = model
        @error = nil
        @calls = []
      end

      def fail_with(error)
        @error = error
        self
      end

      def recover!
        @error = nil
        self
      end

      def perform(texts, model:, dimensions:)
        @calls << { texts: texts, model: model, dimensions: dimensions }
        raise @error if @error

        { vectors: texts.map { |text| vector_for(text, dimensions) }, model: @model || model }
      end

      def vector_for(text, dimensions)
        vector = Array.new(dimensions, 0.0)
        text.to_s.downcase.scan(/[[:alnum:]]+/).each do |token|
          digest = Digest::SHA256.digest(token)
          vector[digest.unpack1("N") % dimensions] += digest.getbyte(4).even? ? 1.0 : -1.0
        end
        norm = Math.sqrt(vector.sum { |value| value * value })
        norm.zero? ? vector : vector.map { |value| value / norm }
      end
    end
  end
end
