module Truffler
  module Embeddings
    # The embedder seam. `embed(texts, model:, dimensions:)` returns one vector
    # per text plus usage, and emits `truffler.embed_call` with tokens, cost,
    # and latency but never the texts. Subclasses implement `perform`,
    # returning {vectors:, model:, input_tokens:}; a missing token count is
    # estimated and flagged.
    class Embedder
      Result = Data.define(:vectors, :model, :input_tokens, :tokens_estimated, :cost)

      def embed(texts, model:, dimensions:)
        texts = Array(texts)
        started = Instrumentation.monotonic_ms
        payload = { model: model, record_count: texts.size }

        response = perform(texts, model: model, dimensions: dimensions)
        result = result_for(response, texts, model)
        payload.merge!(model: result.model, input_tokens: result.input_tokens, tokens_estimated: result.tokens_estimated,
          cost: result.cost)
        result
      rescue Truffler::Error => error
        payload[:error_class] = error.class.name
        raise
      rescue StandardError => error
        wrapped = ClientError.from(error)
        payload.merge!(error_class: wrapped.error_class, status: wrapped.status)
        raise wrapped
      ensure
        Instrumentation.instrument(:embed_call, payload.merge(latency_ms: Instrumentation.monotonic_ms - started))
      end

      def perform(texts, model:, dimensions:)
        raise NotImplementedError, "#{self.class.name}#perform"
      end

      private

      def result_for(response, texts, model)
        vectors = response.fetch(:vectors)
        unless vectors.size == texts.size
          raise IncompleteAnswers, "embedder returned #{vectors.size} vectors for #{texts.size} texts"
        end

        tokens = response[:input_tokens]
        estimated = tokens.nil?
        tokens = estimated ? texts.sum { |text| Tokens.estimate(text) } : tokens.to_i
        cost = tokens * Truffler.config.embedding_cost_per_million_tokens / 1_000_000.0
        Result.new(vectors: vectors.map { |vector| vector.map(&:to_f) }, model: response[:model] || model,
          input_tokens: tokens, tokens_estimated: estimated, cost: cost)
      end
    end
  end
end
