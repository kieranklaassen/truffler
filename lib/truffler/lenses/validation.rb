module Truffler
  module Lenses
    # Checks lens questions against the KTD2 wire shape and Jev's limits
    # before any Jev call: at most 10 score levels and 255 choice options.
    module Validation
      MAX_SCORE_LEVELS = 10
      MAX_CHOICE_OPTIONS = 255
      TYPES = %w[noul choice score].freeze

      module_function

      # questions: {label_key => wire-shape question}; reused: label keys the
      # lens borrows; available: keys it may borrow; declared: keys a new
      # question must not shadow.
      def validate!(questions, reused: [], available: nil, declared: [], max_questions: Lenses.settings.max_questions)
        questions = questions.to_h
        raise InvalidLens, "a lens needs at least one new or reused label" if questions.empty? && reused.blank?
        raise InvalidLens, "a lens may add at most #{max_questions} questions" if questions.size > max_questions

        questions.each { |key, question| check_question(key.to_s, question, declared) }
        unknown = Array(reused).map(&:to_s) - Array(available || reused).map(&:to_s)
        raise InvalidLens, "reused labels #{unknown.join(', ')} do not exist" if unknown.any?

        questions
      end

      def check_question(key, question, declared)
        raise InvalidLens, "label #{key.inspect} must match #{LabelDefinition::KEY.source} without a double underscore" unless
          LabelDefinition::KEY.match?(key) && !key.include?(Questions::SEPARATOR)
        raise InvalidLens, "#{key} is already a declared label; reuse it instead" if declared.include?(key)
        raise InvalidLens, "#{key}: question must be a hash" unless question.is_a?(Hash)

        type = question["type"]
        raise InvalidLens, "#{key}: type must be one of #{TYPES.join(', ')}" unless TYPES.include?(type)
        raise InvalidLens, "#{key}: instructions are required" if question["instructions"].blank?

        criteria = question["criteria"]
        case type
        when "noul" then check_noul(key, criteria)
        when "choice" then check_choice(key, criteria)
        when "score" then check_score(key, criteria)
        end
      end

      def check_noul(key, criteria)
        return if criteria.nil?
        return if criteria.is_a?(Hash) && criteria.keys.map(&:to_s).sort == %w[false true]

        raise InvalidLens, "#{key}: noul criteria keys must be true and false"
      end

      def check_choice(key, criteria)
        raise InvalidLens, "#{key}: choice criteria must be a hash of options" unless criteria.is_a?(Hash) && criteria.any?
        if criteria.size > MAX_CHOICE_OPTIONS
          raise InvalidLens, "#{key}: #{criteria.size} choice options exceed Jev's limit of #{MAX_CHOICE_OPTIONS}"
        end
        raise InvalidLens, "#{key}: choice options must be named" if criteria.keys.any?(&:blank?)
      end

      def check_score(key, criteria)
        raise InvalidLens, "#{key}: score criteria must list ordered levels" unless criteria.is_a?(Array)
        raise InvalidLens, "#{key}: score labels need at least two levels" if criteria.size < 2
        return if criteria.size <= MAX_SCORE_LEVELS

        raise InvalidLens, "#{key}: #{criteria.size} score levels exceed Jev's limit of #{MAX_SCORE_LEVELS}"
      end
    end
  end
end
