module Truffler
  module Search
    # Words that carry no search meaning on their own: common stopwords and
    # `config.filler_words` (generic nouns such as "customers" or "items",
    # matched ignoring plurals). One rule serves the encoder's reconcile and
    # the cold-cache keywords: filler is dropped as a keyword unless dropping
    # it would leave the search with no keyword, no applied label, and no
    # time range, so a lone "customers" still searches text.
    module Filler
      STOPWORDS = %w[
        a about all an and any are at be by for from have i in is it me my now of on or our please so some that the their
        them there they this to up us was we what when where which who why with you your
      ].to_set.freeze

      DEFAULT_WORDS = %w[customer customers people person user users message messages item items stuff thing things].freeze

      module_function

      def stopword?(word)
        STOPWORDS.include?(word.to_s.downcase)
      end

      # `keep` holds singular words that are never filler (see label_words).
      def word?(word, filler_words: Truffler.config.filler_words, keep: nil)
        word = word.to_s.downcase
        return false if keep&.include?(word.singularize)

        stopword?(word) || Array(filler_words).any? { |filler| filler.to_s.downcase.singularize == word.singularize }
      end

      # Singular words that name one of the model's declared labels for this
      # tenant, applied or not: words of a label key, of a choice option key,
      # and of an option's search text (not its description, which is prose).
      # Such a word is never filler, so "text messages" still searches
      # "messages" when an option's search text is "text message".
      def label_words(definition, tenant_key = nil)
        definition.labels.each_value.with_object(Set.new) do |label, words|
          next unless label.available?(tenant_key)

          names = [ label.key ]
          if label.type == :choice
            options = label.encoding_wording(tenant_key)[:options]
            names.concat(options.keys, options.values.filter_map { |entry| entry[:search] })
          end
          names.each do |name|
            name.to_s.downcase.split(/[^\p{Alnum}]+/).each { |word| words << word.singularize unless word.empty? || stopword?(word) }
          end
        end
      end

      # The subset of `candidates` (droppable keywords) to drop, given how many
      # keywords there are and whether a label or time range is applied. When
      # nothing anchors the search and only droppable words are left, the
      # filler nouns stay as keywords and only pure stopwords go ("customers
      # in the" searches "customers"); if every word is a stopword, all stay.
      def drop(candidates, keyword_count:, anchored:, stopword: ->(candidate) { stopword?(candidate) })
        return candidates if anchored || candidates.size < keyword_count

        stopwords = candidates.select(&stopword)
        stopwords.size == candidates.size ? [] : stopwords
      end

      # `tokens` minus filler words, or only minus stopwords when nothing else
      # would anchor the search. Exact tokens (a quoted "the") and `keep`
      # words are never filler.
      def keywords(tokens, anchored:, exact: [], keep: nil)
        dropped = drop(tokens.select { |token| !exact.include?(token) && word?(token, keep: keep) }, keyword_count: tokens.size,
          anchored: anchored)
        tokens - dropped
      end
    end
  end
end
