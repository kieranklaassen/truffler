module Truffler
  module Clients
    # Every adapter answers `ask(state:, questions:, model:, priority:)` with
    # Truffler::Answers. Subclasses implement `perform(state:, questions:,
    # model:)`, returning the parsed TypeSafe body: {"answers", "model",
    # "usage" => {"input_tokens"}}. Only "answers" is required; missing token
    # counts are estimated from the request size and flagged.
    class Base
      def ask(state:, questions:, model: nil, priority: nil)
        model ||= Truffler.config.model
        started = Instrumentation.monotonic_ms
        payload = { priority: priority, question_count: questions.size, model: model }

        response = normalize(perform(state: state, questions: questions, model: model))
        usage = usage_for(response, state, questions)
        answers = Answers.new(response["answers"], requested: questions.keys, model: response["model"] || model, usage: usage)
        payload.merge!(model: answers.model, input_tokens: usage.input_tokens, tokens_estimated: usage.estimated, cost: usage.cost)
        answers
      rescue Truffler::Error => error
        payload[:error_class] = error.class.name
        raise
      rescue StandardError => error
        wrapped = ClientError.from(error)
        payload.merge!(error_class: wrapped.error_class, status: wrapped.status)
        raise wrapped
      ensure
        Instrumentation.instrument(:jev_call, payload.merge(latency_ms: Instrumentation.monotonic_ms - started))
      end

      def perform(state:, questions:, model:)
        raise NotImplementedError, "#{self.class.name}#perform"
      end

      private

      def normalize(response)
        response = response.to_h.deep_stringify_keys
        response.key?("answers") ? response : { "answers" => response }
      end

      def usage_for(response, state, questions)
        tokens = response.dig("usage", "input_tokens")
        return Usage.new(input_tokens: tokens.to_i, estimated: false) if tokens

        Usage.new(input_tokens: Tokens.estimate({ state: state, questions: questions }), estimated: true)
      end
    end
  end
end
