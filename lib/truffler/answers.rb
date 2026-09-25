module Truffler
  # TypeSafe's answers keyed by question id. Scores normalize to 0..1 as
  # score / (levels - 1). A response missing any requested id raises, so
  # callers never act on partial answers.
  class Answers
    attr_reader :raw, :model, :usage

    def initialize(raw, requested: [], model: nil, usage: nil)
      @raw = raw.to_h.deep_stringify_keys
      @model = model
      @usage = usage
      missing = requested.map(&:to_s) - @raw.keys
      raise IncompleteAnswers, "TypeSafe answered without #{missing.join(', ')}" if missing.any?
    end

    def ids
      raw.keys
    end

    def noul(id)
      fetch(id, "noul")["noul"].to_f
    end

    def choice(id)
      fetch(id, "choice")["choice"]
    end

    def probabilities(id)
      fetch(id, "choice")["probabilities"].to_h.transform_values(&:to_f)
    end

    def probability(id, option)
      probabilities(id).fetch(option.to_s, 0.0)
    end

    def score(id)
      answer = fetch(id, "score")
      levels = answer["legend"].to_h.size
      levels > 1 ? answer["score"].to_f / (levels - 1) : answer["score"].to_f
    end

    # One number per answer: a noul's probability, a score's normalized
    # position, or a choice's confidence in its pick.
    def value(id)
      case type(id)
      when "noul" then noul(id)
      when "score" then score(id)
      when "choice" then probability(id, choice(id))
      end
    end

    def type(id)
      fetch(id)["type"]
    end

    private

    def fetch(id, type = nil)
      answer = raw[id.to_s]
      raise IncompleteAnswers, "no answer for #{id}" unless answer.is_a?(Hash)
      raise IncompleteAnswers, "expected a #{type} answer for #{id}" if type && answer["type"] != type

      answer
    end
  end
end
