module Truffler
  module Search
    # Words that carry no search meaning on their own: common stopwords and
    # `config.filler_words` (generic nouns such as "customers" or "emails",
    # matched ignoring plurals). One rule serves the encoder's reconcile and
    # the cold-cache keywords: filler is dropped as a keyword unless dropping
    # it would leave the search with no keyword, no applied label, and no
    # time range, so a lone "customers" still searches text.
    module Filler
      STOPWORDS = %w[
        a about all an and any are at be by for from have i in is it me my now of on or our please so some that the their
        them there they this to up us was we what when where which who why with you your
      ].to_set.freeze

      DEFAULT_WORDS = %w[customer customers people person user users message messages email emails item items stuff thing things].freeze

      module_function

      def stopword?(word)
        STOPWORDS.include?(word.to_s.downcase)
      end

      def word?(word, filler_words: Truffler.config.filler_words)
        word = word.to_s.downcase
        stopword?(word) || Array(filler_words).any? { |filler| filler.to_s.downcase.singularize == word.singularize }
      end

      # The subset of `candidates` (droppable keywords) to drop, given how many
      # keywords there are and whether a label or time range is applied.
      def drop(candidates, keyword_count:, anchored:)
        return [] if !anchored && candidates.size == keyword_count

        candidates
      end

      # `tokens` minus filler words, or all of them when nothing else would
      # anchor the search. Exact tokens (a quoted "the") are never filler.
      def keywords(tokens, anchored:, exact: [])
        dropped = drop(tokens.select { |token| !exact.include?(token) && word?(token) }, keyword_count: tokens.size, anchored: anchored)
        tokens - dropped
      end
    end
  end
end
