module Truffler
  module Clients
    # Deterministic scripted answers for tests and benchmarks. Script by exact
    # question id or by label suffix (`:spam` matches `r001__spam`):
    #
    #   fake.answer(:spam, 0.9)                         # noul probability
    #   fake.answer(:tone, "angry")                     # choice option
    #   fake.answer(:tone, { "calm" => 0.2, "angry" => 0.8 })
    #   fake.answer(:urgency, 2)                        # score level
    #   fake.answer(:spam) { |tag, state| state.dig("records", tag, "body").include?("$$$") ? 0.9 : 0.1 }
    #
    # Unscripted questions answer no, the lowest level, or for a choice its
    # neutral option when it has one (`ignore` for a query-encoding intent,
    # `Truffler::NO_OPTION` for an option question, `keyword` for a word
    # role), else the first option. So an unscripted query encoding applies
    # no label.
    class Fake < Base
      NEUTRAL_OPTIONS = [ "ignore", NO_OPTION, "keyword" ].freeze

      attr_reader :calls

      def initialize(model: nil, &default)
        @model = model
        @default = default
        @scripts = {}
        @omitted = []
        @error = nil
        @calls = []
      end

      def answer(key, value = nil, &block)
        @scripts[key.to_s] = block || value
        self
      end

      def answer_without(*ids)
        @omitted = ids.map(&:to_s)
        self
      end

      def fail_with(error)
        @error = error
        self
      end

      def perform(state:, questions:, model:)
        @calls << { state: state, questions: questions, model: model }
        raise @error if @error

        answers = questions.except(*@omitted).to_h { |id, question| [ id, answer_for(id, question, state) ] }
        { "answers" => answers, "model" => @model || model }
      end

      private

      def answer_for(id, question, state)
        tag, label = Questions.split_id(id)
        script = @scripts.fetch(id) { @scripts[label] if label }
        script = @default if script.nil?
        value = script.respond_to?(:call) ? script.call(tag, state.deep_stringify_keys, id) : script
        shape(question, value)
      end

      def shape(question, value)
        case question["type"]
        when "noul" then { "type" => "noul", "noul" => value.to_f }
        when "choice" then choice(question["criteria"].keys, value)
        when "score" then score(question["criteria"].size, value.to_f)
        end
      end

      def choice(options, value)
        probabilities = options.to_h { |option| [ option, 0.0 ] }
        case value
        when Hash then probabilities.merge!(value.transform_keys(&:to_s).transform_values(&:to_f))
        when nil then probabilities[(NEUTRAL_OPTIONS & options).first || options.first] = 1.0
        else probabilities[value.to_s] = 1.0
        end
        pick, confidence = probabilities.max_by { |_, probability| probability }
        { "type" => "choice", "choice" => pick, "probabilities" => probabilities, "confidence" => confidence }
      end

      def score(levels, level)
        legend = Array.new(levels) { |index| [ index.to_s, index.to_s ] }.to_h
        probabilities = legend.keys.to_h { |key| [ key, key.to_i == level.round ? 1.0 : 0.0 ] }
        { "type" => "score", "score" => level, "legend" => legend, "probabilities" => probabilities,
          "confidence" => 1.0 }
      end
    end
  end
end
