module Truffler
  module Clients
    # Wraps a host client whose `evaluate(state:, schema:)` takes a schema
    # object (it reads `schema.questions`) and returns an evaluation object
    # with `answers`, `model`, and `input_tokens` (or a `usage` hash) readers
    # instead of a hash, such as Cora's TypeSafeClient and its
    # TypeSafe::Evaluation. The schema also reads like the question hash, so
    # a client that treats it as a Hash works too. The pinned model is passed
    # when the host's method accepts `model:`.
    #
    #   config.client = Truffler::Clients::Evaluator.new(TypeSafeClient.new)
    class Evaluator < Callable
      Schema = Data.define(:questions) do
        delegate :[], :each, :keys, :size, :empty?, :as_json, :to_json, to: :questions

        def ids
          questions.keys
        end

        def to_h
          questions
        end
      end

      def perform(state:, questions:, model:)
        response(super(state: state, questions: Schema.new(questions: questions), model: model))
      end

      private

      def response(evaluation)
        return evaluation if evaluation.is_a?(Hash)

        tokens = evaluation.try(:input_tokens) || usage_tokens(evaluation.try(:usage))
        { "answers" => evaluation.answers.to_h, "model" => evaluation.try(:model),
          "usage" => ({ "input_tokens" => tokens } if tokens) }.compact
      end

      def usage_tokens(usage)
        usage.is_a?(Hash) ? usage.with_indifferent_access[:input_tokens] : usage.try(:input_tokens)
      end
    end
  end
end
