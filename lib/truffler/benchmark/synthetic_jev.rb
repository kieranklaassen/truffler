require "digest"

module Truffler
  module Benchmark
    # A deterministic stand-in for Jev that answers from the dataset's ground
    # truth plus seeded noise. It produces the committed cassettes. Packed
    # requests drift: each extra record in a request raises the chance that
    # an answer flips, which is what the R33 agreement check has to catch.
    # With obey_injections it follows instructions embedded in record text,
    # modeling a model that fails R34.
    #
    # Questions about records it does not know (rerank candidates, queries)
    # answer no, the first option, or the lowest level.
    class SyntheticJev < Clients::Base
      MODEL = "synthetic-jev".freeze
      INJECTED = "ignore all previous instructions".freeze
      OBEYED = { "needs_action" => 1.0, "urgent" => 1.0, "category" => "billing", "importance" => 2 }.freeze

      def initialize(dataset, seed: Generator::DEFAULT_SEED, noise: 0.03, packed_flip_rate: 0.003, obey_injections: false)
        @seed = seed
        @noise = noise
        @packed_flip_rate = packed_flip_rate
        @obey_injections = obey_injections
        @truth = dataset.labeled_records.to_h { |record| [ self.class.key(record.to_h.stringify_keys), record.truth ] }
      end

      def self.key(fields)
        Canonical.digest([ fields["subject"].to_s, fields["body"].to_s ])
      end

      def perform(state:, questions:, model:)
        state = state.deep_stringify_keys
        records = state["records"].to_h
        answers = questions.to_h do |id, question|
          tag, label = Questions.split_id(id)
          [ id, answer(question.deep_stringify_keys, records[tag], label, records.size) ]
        end
        { "answers" => answers, "model" => MODEL, "usage" => { "input_tokens" => Tokens.estimate({ state: state, questions: questions }) } }
      end

      private

      def answer(question, fields, label, batch)
        key = fields && self.class.key(fields)
        truth = key && @truth[key]
        truth = OBEYED if truth && @obey_injections && fields["body"].to_s.downcase.include?(INJECTED)
        flip = truth && unit(key, label, batch, "flip") < @packed_flip_rate * (batch - 1)
        drift = truth ? (unit(key, label, batch, "noise") * 2 - 1) * @noise : 0.0

        case question["type"]
        when "noul" then noul(truth&.dig(label).to_f, drift, flip)
        when "choice" then choice(question["criteria"].keys, truth&.dig(label), drift, flip)
        when "score" then score(question["criteria"].size, truth&.dig(label).to_i, flip)
        end
      end

      def noul(value, drift, flip)
        value = (value + drift).clamp(0.0, 1.0)
        value = value >= 0.5 ? value - 0.4 : value + 0.4 if flip
        { "type" => "noul", "noul" => value.round(4) }
      end

      def choice(options, truth, drift, flip)
        index = options.index(truth.to_s) || 0
        index = (index + 1) % options.size if flip
        confidence = (0.8 + drift).round(4)
        rest = options.size > 1 ? ((1 - confidence) / (options.size - 1)).round(4) : 0.0
        probabilities = options.each_with_index.to_h { |option, position| [ option, position == index ? confidence : rest ] }
        { "type" => "choice", "choice" => options[index], "probabilities" => probabilities, "confidence" => confidence }
      end

      def score(levels, level, flip)
        level = level.clamp(0, levels - 1)
        level = level.zero? ? 1 : level - 1 if flip
        legend = Array.new(levels) { |index| [ index.to_s, index.to_s ] }.to_h
        probabilities = legend.keys.to_h { |key| [ key, key.to_i == level ? 1.0 : 0.0 ] }
        { "type" => "score", "score" => level, "legend" => legend, "probabilities" => probabilities, "confidence" => 1.0 }
      end

      def unit(*parts)
        Digest::SHA256.hexdigest([ @seed, *parts ].join("|"))[0, 8].to_i(16) / 0xffffffff.to_f
      end
    end
  end
end
