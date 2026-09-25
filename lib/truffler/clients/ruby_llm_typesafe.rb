require "ruby_llm"
require "ruby_llm-typesafe"

module Truffler
  module Clients
    # The default adapter: TypeSafe through RubyLLM 2 and ruby_llm-typesafe.
    # Neither gem is a truffler dependency; this file loads only when the
    # adapter is selected.
    class RubyLLMTypeSafe < Base
      def perform(state:, questions:, model:)
        message = chat(model: model, provider: :typesafe).with_schema(schema_for(questions)).ask(JSON.generate(state))
        { "answers" => message.parsed, "model" => message.model, "usage" => { "input_tokens" => message.tokens&.input } }
      end

      private

      def chat(**options)
        RubyLLM.chat(**options)
      end

      def schema_for(questions)
        RubyLLM::Providers::TypeSafe::Schema.new do |schema|
          questions.each do |id, question|
            options = { instructions: question["instructions"] }
            options[:criteria] = question["criteria"] if question.key?("criteria")
            schema.public_send(question["type"], id, **options)
          end
        end
      end
    end
  end
end
