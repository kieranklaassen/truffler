module Truffler
  # Builds TypeSafe questions as plain wire-shape hashes keyed by string id:
  #
  #   Truffler::Questions.build do |q|
  #     q.noul :spam, instructions: "Is this spam?", criteria: { true => "...", false => "..." }
  #     q.choice :tone, instructions: "Tone?", criteria: { calm: nil, angry: "Hostile words" }
  #     q.score :urgency, instructions: "How urgent?", criteria: [ "Whenever", "Today" ]
  #   end
  class Questions
    ID = /\A[a-z0-9_]+\z/
    SEPARATOR = "__".freeze

    def self.build
      new.tap { |questions| yield questions }.to_h
    end

    def self.tag(prefix, index)
      format("%s%03d", prefix, index)
    end

    def self.tagged_id(tag, key)
      "#{tag}#{SEPARATOR}#{key}"
    end

    def self.split_id(id)
      id.to_s.split(SEPARATOR, 2)
    end

    def self.valid_id?(id)
      ID.match?(id.to_s)
    end

    def initialize
      @questions = {}
    end

    def noul(id, instructions:, criteria: nil)
      criteria = criteria&.to_h { |answer, description| [ answer.to_s, description ] }
      if criteria && !(criteria.keys - %w[true false]).empty?
        raise ArgumentError, "#{id}: noul criteria keys must be true and false"
      end

      add(id, "noul", instructions, criteria)
    end

    def choice(id, instructions:, criteria:)
      criteria = criteria.to_h { |option| [ option, nil ] } if criteria.is_a?(Array)
      raise ArgumentError, "#{id}: choice criteria must name at least one option" if criteria.blank?

      add(id, "choice", instructions, criteria.to_h { |option, description| [ option.to_s, description ] })
    end

    def score(id, instructions:, criteria:)
      levels = criteria.is_a?(Hash) ? criteria.sort_by { |level, _| level.to_i }.map(&:last) : Array(criteria)
      raise ArgumentError, "#{id}: score criteria need at least two ordered levels" if levels.size < 2

      add(id, "score", instructions, levels)
    end

    def to_h
      @questions.deep_dup
    end

    private

    def add(id, type, instructions, criteria)
      key = id.to_s
      raise ArgumentError, "question id #{id.inspect} must match #{ID.source}" unless self.class.valid_id?(key)
      raise ArgumentError, "question id #{key} is already defined" if @questions.key?(key)
      raise ArgumentError, "#{key}: instructions are required" if instructions.blank?

      question = { "type" => type, "instructions" => Canonical.sort(instructions) }
      question["criteria"] = criteria unless criteria.nil?
      @questions[key] = question
      self
    end
  end
end
