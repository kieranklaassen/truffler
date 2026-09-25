require "ruby_llm"

module Truffler
  module Lenses
    # The default drafting model: `RubyLLM.chat(...).with_schema(...)`, which
    # ruby_llm 1.x and 2 share. 1.x parses structured output into `content`;
    # 2 keeps `content` as text and parses it in `parsed`. ruby_llm is not a
    # truffler dependency; this file loads only when the default is used.
    class RubyLLMGenerator
      def generate(prompt:, schema:, model: nil)
        message = chat(**{ model: model }.compact).with_schema(schema).ask(prompt)
        { draft: parsed(message), model: model_of(message), input_tokens: input_tokens(message) }
      end

      private

      def chat(**options)
        RubyLLM.chat(**options)
      end

      def parsed(message)
        body = message.respond_to?(:parsed) ? message.parsed : message.content
        body = JSON.parse(body) if body.is_a?(String)
        raise InvalidLens, "the drafting model returned no structured draft" unless body.is_a?(Hash)

        body
      rescue JSON::ParserError
        raise InvalidLens, "the drafting model returned malformed JSON"
      end

      def model_of(message)
        (message.respond_to?(:model_id) && message.model_id) || (message.respond_to?(:model) && message.model) || nil
      end

      def input_tokens(message)
        return message.input_tokens if message.respond_to?(:input_tokens) && message.input_tokens

        message.tokens&.input if message.respond_to?(:tokens)
      end
    end
  end
end
