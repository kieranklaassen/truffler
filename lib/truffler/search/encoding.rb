module Truffler
  module Search
    # What query encoding (U9) decided about one query, as keystroke search
    # reads it from the cache. Keys are label storage keys (`needs_action`,
    # `category:billing`, `lens:<id>:<label>`).
    #
    # - `filters`: hard filters, key => minimum value, applied as EXISTS.
    # - `boosts`: key => weight, shown as boost chips.
    # - `intent_vector`: the sparse query vector of KTD20, key => weight, used
    #   for the label term SUM(weight * value). Defaults to `boosts`; the
    #   encoder decides whether filtered labels also carry weight here.
    # - `keyword_tokens`: query tokens for the keyword source; nil means
    #   every token that is not a label term or filler.
    # - `label_term_tokens`: tokens that named a label rather than a keyword.
    # - `label_term_sources`: label-term token => the applied storage keys it
    #   named. Once the searcher removes every one of them, the token is a
    #   keyword again.
    # - `soft_keyword_tokens`: label terms that named a label or option key
    #   only by shared prefix ("urgently" for urgent). They add a small
    #   keyword score and are never required.
    # - `filler_tokens`: stopwords and filler words the encoder dropped.
    #   Removing the chips that justified the drop brings filler nouns back.
    # - `time`: the query's `TimeRange`, resolved at search time and never
    #   cached, since "today" moves.
    Encoding = Data.define(:filters, :boosts, :intent_vector, :keyword_tokens, :label_term_tokens, :label_term_sources,
      :soft_keyword_tokens, :filler_tokens, :time) do
      def self.load(value, query)
        return value if value.is_a?(self)
        return if value.nil?

        tokens = query.tokens
        new(filters: value["filters"], boosts: value["boosts"], intent_vector: value["intent_vector"],
          keyword_tokens: value["keyword_positions"]&.map { |position| tokens[position] }&.compact,
          label_term_tokens: Array(value["label_term_positions"]).filter_map { |position| tokens[position] },
          label_term_sources: Array(value["label_term_sources"]).filter_map { |position, keys| [ tokens[position], keys ] if tokens[position] },
          soft_keyword_tokens: Array(value["soft_keyword_positions"]).filter_map { |position| tokens[position] },
          filler_tokens: Array(value["filler_positions"]).filter_map { |position| tokens[position] })
      end

      def initialize(filters: {}, boosts: {}, intent_vector: nil, keyword_tokens: nil, label_term_tokens: [], label_term_sources: {},
        soft_keyword_tokens: [], filler_tokens: [], time: nil)
        filters = weights(filters)
        boosts = weights(boosts)
        intent_vector = weights(intent_vector || boosts).reject { |_, weight| weight.zero? }
        sources = label_term_sources.to_h { |token, keys| [ token.to_s, Array(keys).map(&:to_s).freeze ] }
        super(filters: filters.freeze, boosts: boosts.freeze, intent_vector: intent_vector.freeze,
          keyword_tokens: keyword_tokens&.map(&:to_s)&.freeze, label_term_tokens: Array(label_term_tokens).map(&:to_s).freeze,
          label_term_sources: sources.freeze, soft_keyword_tokens: Array(soft_keyword_tokens).map(&:to_s).freeze,
          filler_tokens: Array(filler_tokens).map(&:to_s).freeze, time: time)
      end

      def empty?
        filters.empty? && boosts.empty? && intent_vector.empty?
      end

      # The encoding minus the chips the searcher removed (R20), matched by
      # storage key or by label key; "time" removes the time range. A label
      # term whose every source label is gone becomes a keyword again. `keep_words`
      # (a set, or a callable returning one) holds the words that are never
      # filler, as in `keywords`.
      def without(suppressed, keep_words: nil)
        suppressed = Array(suppressed).map(&:to_s).to_set
        return self if suppressed.empty?

        keep = ->(key, _) { !suppressed.include?(key) && !suppressed.include?(self.class.split_key(key).first) }
        kept = { filters: filters.select(&keep), boosts: boosts.select(&keep), intent_vector: intent_vector.select(&keep) }
        applied = kept.values.flat_map(&:keys).to_set
        freed = label_term_sources.select { |_, keys| keys.any? && keys.none? { |key| applied.include?(key) } }.keys
        kept_time = (time unless suppressed.include?(TimeRange.key))
        keywords = keyword_tokens && (keyword_tokens + freed).uniq
        if keywords && applied.empty? && kept_time.nil?
          keywords = Filler.keywords(keywords + filler_tokens, anchored: false, keep: keep_words.respond_to?(:call) ? keep_words.call : keep_words)
        end
        with(**kept, time: kept_time, label_term_tokens: label_term_tokens - freed,
          label_term_sources: label_term_sources.except(*freed), soft_keyword_tokens: soft_keyword_tokens - freed,
          keyword_tokens: keywords)
      end

      # Splits a storage key into its label key and choice option. Lens keys
      # ("lens:<id>:<label>[:<option>]") carry two extra colons.
      def self.split_key(key)
        key = key.to_s
        if key.start_with?("#{Lenses::KEY_PREFIX}:")
          prefix, id, label, option = key.split(":", 4)
          [ "#{prefix}:#{id}:#{label}", option ]
        else
          key.split(":", 2)
        end
      end

      # Without encoder decisions (a cold cache), every search token that is
      # not a label term, minus filler words (see Filler). `keep` is called
      # only then, for the words that are never filler.
      def keywords(query, keep: nil)
        keyword_tokens ||
          Filler.keywords(query.search_tokens - label_term_tokens, anchored: !empty? || !time.nil?, exact: query.exact_tokens,
            keep: keep&.call)
      end

      # The cache form: decisions plus token positions in the normalized
      # query, so no query text is stored (the cache key already fixes the
      # query).
      def dump(query)
        { "filters" => filters, "boosts" => boosts, "intent_vector" => intent_vector,
          "keyword_positions" => keyword_tokens && positions(query, keyword_tokens),
          "label_term_positions" => positions(query, label_term_tokens),
          "label_term_sources" => query.tokens.each_index.filter_map do |position|
            [ position, label_term_sources[query.tokens[position]] ] if label_term_sources.key?(query.tokens[position])
          end,
          "soft_keyword_positions" => positions(query, soft_keyword_tokens),
          "filler_positions" => positions(query, filler_tokens) }
      end

      private

      def weights(hash)
        hash.to_h.to_h { |key, weight| [ key.to_s, Float(weight) ] }
      end

      def positions(query, words)
        query.tokens.each_index.select { |index| words.include?(query.tokens[index]) }
      end
    end
  end
end
