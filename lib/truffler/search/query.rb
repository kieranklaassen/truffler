module Truffler
  module Search
    # A normalized, tokenized search query. Quoted phrases stay one token.
    # Exact-text signals (quoted phrases, digit-bearing tokens, emails, and
    # identifier shapes such as `INV-4471` or `order_id`) are detected
    # locally and never asked of Jev (R18), and so is a time phrase ("this
    # week"), whose words are neither exact tokens nor keywords.
    class Query
      QUOTED = /"([^"]*)"/
      EMAIL = /\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/
      IDENTIFIER = /\A[a-z0-9]+(?:[-_.][a-z0-9]+)+\z/
      EDGE_PUNCTUATION = /\A[^\p{Alnum}@]+|[^\p{Alnum}]+\z/

      attr_reader :raw, :normalized, :tokens, :exact_tokens, :time_phrase

      def self.wrap(query)
        query.is_a?(self) ? query : new(query)
      end

      def self.normalize(text)
        text.to_s.unicode_normalize(:nfkc).downcase.squish
      end

      def initialize(raw)
        @raw = raw.to_s
        @normalized = self.class.normalize(raw)
        @tokens, exact = tokenize(normalized)
        @time_phrase = TimePhrase.find(@tokens)
        @exact_tokens = exact.reject { |position| time_position?(position) }.map { |position| @tokens[position] }.freeze
      end

      def time_position?(position)
        time_phrase&.positions&.include?(position) || false
      end

      # The tokens a keyword source may match: all but the time phrase.
      def search_tokens
        tokens.each_index.reject { |position| time_position?(position) }.map { |position| tokens[position] }
      end

      def blank?
        tokens.empty?
      end

      def exact_text?
        exact_tokens.any?
      end

      private

      def tokenize(text)
        tokens = []
        exact = []
        text.split(QUOTED, -1).each_with_index do |part, index|
          if index.odd?
            phrase = part.squish
            next if phrase.empty?

            exact << tokens.size
            tokens << phrase
          else
            part.split.each do |word|
              word = word.gsub(EDGE_PUNCTUATION, "")
              next if word.empty?

              exact << tokens.size if exact?(word)
              tokens << word
            end
          end
        end
        [ tokens.freeze, exact ]
      end

      def exact?(word)
        word.match?(/\d/) || word.match?(EMAIL) || word.match?(IDENTIFIER)
      end
    end
  end
end
