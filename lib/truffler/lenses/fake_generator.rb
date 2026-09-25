module Truffler
  module Lenses
    # Deterministic drafts for tests and benchmarks. Script a draft for a
    # description pattern, or pass a block that receives the parsed prompt:
    #
    #   fake.draft(/dutch/i, reuse: [ "sentiment" ], questions: [
    #     { key: "language", type: "choice", instructions: "Which language?", options: %w[dutch other] }
    #   ])
    #
    # The most recent matching script wins. Unscripted descriptions draft one
    # yes/no question about the description.
    class FakeGenerator
      attr_reader :calls

      def initialize(&default)
        @default = default
        @scripts = []
        @calls = []
      end

      def draft(pattern, name: nil, reuse: [], questions: [])
        @scripts << [ pattern, { name: name, reuse: reuse, questions: questions } ]
        self
      end

      def generate(prompt:, schema:, model: nil)
        @calls << { prompt: prompt, schema: schema, model: model }
        request = JSON.parse(prompt)
        description = request["description"].to_s
        _, script = @scripts.reverse_each.find { |pattern, _| pattern === description }
        body = script ? wire(script) : default_draft(request, description)
        { draft: body.deep_stringify_keys, model: model || "fake-drafter", input_tokens: Tokens.estimate(prompt) }
      end

      private

      def default_draft(request, description)
        return @default.call(request) if @default

        { name: description.first(40), reuse: [],
          questions: [ { key: "matches_lens", type: "noul", instructions: "Does this record match: #{description}?" } ] }
      end

      def wire(script)
        questions = script[:questions].map do |question|
          question = question.to_h.symbolize_keys
          options = Array(question[:options]).map do |option|
            option.is_a?(Hash) ? option : { name: option.to_s, description: "" }
          end
          { key: question[:key].to_s, type: question[:type].to_s, instructions: question[:instructions].to_s,
            criteria_true: question[:criteria_true].to_s, criteria_false: question[:criteria_false].to_s,
            options: options, levels: Array(question[:levels]).map(&:to_s) }
        end
        { name: script[:name].to_s, reuse: script[:reuse].map(&:to_s), questions: questions }
      end
    end
  end
end
