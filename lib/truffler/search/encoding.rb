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
    #   every token that is not a label term.
    # - `label_term_tokens`: tokens that named a label rather than a keyword.
    Encoding = Data.define(:filters, :boosts, :intent_vector, :keyword_tokens, :label_term_tokens) do
      def self.load(value, query)
        return value if value.is_a?(self)
        return if value.nil?

        tokens = query.tokens
        new(filters: value["filters"], boosts: value["boosts"], intent_vector: value["intent_vector"],
          keyword_tokens: value["keyword_positions"]&.map { |position| tokens[position] }&.compact,
          label_term_tokens: Array(value["label_term_positions"]).filter_map { |position| tokens[position] })
      end

      def initialize(filters: {}, boosts: {}, intent_vector: nil, keyword_tokens: nil, label_term_tokens: [])
        filters = weights(filters)
        boosts = weights(boosts)
        intent_vector = weights(intent_vector || boosts).reject { |_, weight| weight.zero? }
        super(filters: filters.freeze, boosts: boosts.freeze, intent_vector: intent_vector.freeze,
          keyword_tokens: keyword_tokens&.map(&:to_s)&.freeze, label_term_tokens: Array(label_term_tokens).map(&:to_s).freeze)
      end

      def empty?
        filters.empty? && boosts.empty? && intent_vector.empty?
      end

      # The encoding minus the chips the searcher removed (R20), matched by
      # storage key or by label key.
      def without(suppressed)
        suppressed = Array(suppressed).map(&:to_s).to_set
        return self if suppressed.empty?

        keep = ->(key, _) { !suppressed.include?(key) && !suppressed.include?(key.split(":").first) }
        with(filters: filters.select(&keep), boosts: boosts.select(&keep), intent_vector: intent_vector.select(&keep))
      end

      def keywords(query)
        keyword_tokens || (query.tokens - label_term_tokens)
      end

      # The cache form: decisions plus token positions in the normalized
      # query, so no query text is stored (the cache key already fixes the
      # query).
      def dump(query)
        { "filters" => filters, "boosts" => boosts, "intent_vector" => intent_vector,
          "keyword_positions" => keyword_tokens && positions(query, keyword_tokens),
          "label_term_positions" => positions(query, label_term_tokens) }
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
