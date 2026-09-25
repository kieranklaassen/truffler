module Truffler
  module QueryEncoding
    # Encodes one pending query (KTD9). It asks a fixed question set: each
    # label gets `filter | boost | ignore`, each choice label also gets its
    # options plus `Truffler::NO_OPTION`, and each of the first 12 word tokens gets
    # `keyword | label_term | filler`. Exact-text tokens (digits, dates,
    # quoted phrases, emails, identifiers) are keywords decided locally and
    # never asked (R18). Query text travels only in `state` ("query" and
    # "tokens"); a token question names its word by position, `tokens[n]`,
    # so searcher text never lands in an instruction (R8). The label
    # vocabulary, with choice option display names, rides along in
    # `state["labels"]` so a token question can tell a word that names a
    # label from text to match.
    #
    # Jev's word roles are then reconciled locally: a keyword that names a
    # label the query applies (its key, a word of its key, the chosen option,
    # or a word of that option's display name, ignoring case and plurals, or
    # sharing its first three letters) becomes a label term, and a common
    # stopword or `config.filler_words` noun becomes filler.
    #
    # Answers become a `Search::Encoding` with the KTD20 intent vector: boost
    # gives the declared boost, filter narrows and adds `filter_weight`
    # (default 0), ignore gives nothing. The encoding is cached whenever it
    # lands, late or not (AE6). With gem-managed embeddings the query vector
    # is embedded and cached in the same pass.
    class Encoder
      INTENTS = {
        "filter" => "The query asks only for records where this holds",
        "boost" => "The query prefers records where this holds but does not require it",
        "ignore" => "The query does not mention this"
      }.freeze
      TOKEN_ROLES = {
        "keyword" => "A word to match in the record text",
        "label_term" => "A word that names one of the labels in `labels`, or one of its options, rather than text to match",
        "filler" => "A word that carries no meaning for the search"
      }.freeze
      NO_OPTION = Truffler::NO_OPTION
      STOPWORDS = Search::Filler::STOPWORDS

      Request = Data.define(:state, :questions, :token_ids, :exact_tokens, :unasked_tokens)

      attr_reader :client, :budget, :cache

      def initialize(client: Truffler.config.client, budget: Budget.new, cache: Cache.new,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
        @client = client
        @budget = budget
        @cache = cache
        @clock = clock
        @sleeper = sleeper
      end

      def request(model, query, tenant_key:, user_key: nil)
        labels = labels(model, tenant_key, user_key)
        questions = Questions.new
        labels.each_value do |label|
          questions.choice(:"intent__#{label.question_key}", instructions: intent_instructions(label), criteria: INTENTS)
        end
        labels.each_value do |label|
          next unless label.type == :choice

          options = label.options(tenant_key).merge(NO_OPTION => "The query names none of these")
          questions.choice(:"option__#{label.question_key}", instructions: %(Which "#{label.key}" option does the search query ask about?),
            criteria: options)
        end

        words = query.tokens.each_with_index.reject do |token, position|
          query.exact_tokens.include?(token) || query.time_position?(position)
        end
        asked = words.first(MAX_TOKEN_QUESTIONS)
        token_ids = asked.to_h do |_token, position|
          id = :"token__#{position}"
          questions.choice(id, instructions: %(In the search query, what is the word tokens[#{position}]? The labels it may name, ) +
            %(with their options, are in `labels`.), criteria: TOKEN_ROLES)
          [ position, id.to_s ]
        end

        state = { "query" => query.normalized, "tokens" => query.tokens, "labels" => vocabulary_state(labels, tenant_key) }
        Request.new(state: state, questions: questions.to_h, token_ids: token_ids, exact_tokens: query.exact_tokens,
          unasked_tokens: words.drop(MAX_TOKEN_QUESTIONS).map(&:first))
      end

      # Encodes the query pending under `cache_key`. Returns the encoding, or
      # nil when the payload expired, the vocabulary moved on, or the encode
      # budget was denied (a silent skip). Always releases the in-flight marker.
      def encode(cache_key)
        pending = cache.read_payload(cache_key)
        return unless pending

        model, query, tenant_key, user_key = pending.values_at(:model, :query, :tenant_key, :user_key)
        return unless cache.key(model, query, tenant_key: tenant_key, user_key: user_key) == cache_key

        encoding = cache.encoded?(cache_key) ? cache.read_encoding(cache_key, query) : encode_labels(model, query, tenant_key, user_key)
        embed_query(model, query, tenant_key)
        encoding
      ensure
        cache.release(cache_key)
      end

      # Polls the cache until the encoding lands or the deadline (seconds
      # from now) passes; nil at the deadline. Pass `query:` to recover the
      # keyword and label-term tokens; otherwise the pending payload supplies it.
      def await(cache_key, deadline:, query: nil, interval: 0.05)
        stop = @clock.call + deadline.to_f
        query ||= cache.read_payload(cache_key)&.dig(:query)
        loop do
          return cache.read_encoding(cache_key, query) if cache.encoded?(cache_key)

          remaining = stop - @clock.call
          return if remaining <= 0

          @sleeper.call([ interval, remaining ].min)
        end
      end

      def encoding_for(model, request, answers, tenant_key:, user_key: nil)
        filters = {}
        boosts = {}
        intent = {}
        names = {}
        labels(model, tenant_key, user_key).each_value do |label|
          key = storage_key(label, answers, tenant_key)
          next unless key

          case answers.choice("intent__#{label.question_key}")
          when "filter"
            filters[key] = label.filter_at || DEFAULT_FILTER_AT
            intent[key] = label.filter_weight
          when "boost"
            boosts[key] = intent[key] = label.boost || DEFAULT_BOOST
          else next
          end
          names[key] = [ label_terms(key), name_terms(option_name(label, key, tenant_key)) ]
        end

        query = Search::Query.new(request.state["query"])
        roles, sources, soft = reconcile(query, request.token_ids.transform_values { |id| answers.choice(id) }, names,
          Search::Filler.label_words(model.truffler_definition, tenant_key))
        tokens = ->(positions) { positions.map { |position| query.tokens[position] } }
        Search::Encoding.new(filters: filters, boosts: boosts, intent_vector: intent,
          keyword_tokens: tokens.call(roles.keys.select { |position| roles[position] == "keyword" }),
          label_term_tokens: tokens.call(sources.keys), soft_keyword_tokens: tokens.call(soft).uniq,
          filler_tokens: tokens.call(roles.keys.select { |position| roles[position] == "filler" }).uniq,
          label_term_sources: sources.group_by { |position, _| query.tokens[position] }.transform_values { |pairs| pairs.flat_map(&:last).uniq })
      end

      private

      def encode_labels(model, query, tenant_key, user_key)
        return if labels(model, tenant_key, user_key).empty?

        started = Instrumentation.monotonic_ms
        decision = budget.acquire(priority: :encode, user_key: user_key)
        if decision.denied?
          instrument(model, tenant_key, started, outcome: "skipped", reason: decision.reason)
          return
        end

        request = request(model, query, tenant_key: tenant_key, user_key: user_key)
        answers = client.ask(state: request.state, questions: request.questions, priority: decision.priority)
        encoding = encoding_for(model, request, answers, tenant_key: tenant_key, user_key: user_key)
        cache.write(model, query, encoding, tenant_key: tenant_key, user_key: user_key)
        Misses.hook.call(model, tenant_key: tenant_key, user_key: user_key, query: query.normalized) if encoding.empty?
        instrument(model, tenant_key, started, outcome: encoding.empty? ? "empty" : "encoded", question_count: request.questions.size,
          filter_count: encoding.filters.size, boost_count: encoding.intent_vector.size)
        encoding
      end

      def embed_query(model, query, tenant_key)
        definition = model.truffler_definition
        return unless Embeddings.managed?(definition) && cache.read_vector(model, query, tenant_key: tenant_key).nil?

        settings = definition.embeddings
        vector = Embeddings.embedder.embed([ query.normalized ], model: settings[:model], dimensions: settings[:dimensions]).vectors.first
        cache.write_vector(model, query, vector, tenant_key: tenant_key)
      end

      def labels(model, tenant_key, user_key)
        model.truffler_definition.vocabulary.labels_for(tenant_key: tenant_key, user_key: user_key)
      end

      # The label's storage key the query names, or nil for a choice label
      # whose option answer is NO_OPTION.
      def storage_key(label, answers, tenant_key)
        return label.key unless label.type == :choice

        option = answers.choice("option__#{label.question_key}")
        "#{label.key}:#{option}" if option != NO_OPTION && label.options(tenant_key).key?(option)
      end

      def vocabulary_state(labels, tenant_key)
        labels.transform_values do |label|
          entry = { "description" => label.description }
          if label.type == :choice
            entry["options"] = label.options(tenant_key).keys
            names = label.option_names(tenant_key)
            entry["option_names"] = names if names.any?
          end
          entry
        end
      end

      # Returns `[roles, sources, soft]`: {position => role} for every token,
      # {label-term position => applied storage keys it names}, and the
      # label-term positions that named a key only by prefix. Time phrase
      # words are "time"; exact tokens and unasked words are keywords; a
      # keyword naming an applied label becomes a label term; stopwords and
      # filler words become filler unless they are all that would be left of
      # an encoding that applies no label and no time range (Search::Filler).
      # A word naming any declared label (`keep`, see Filler.label_words) is
      # never filler, even when Jev calls it that. A word Jev called a label
      # term that names no applied label locally is sourced to every applied
      # label.
      def reconcile(query, answered, names, keep)
        roles = query.tokens.each_index.to_h do |position|
          role = query.time_position?(position) ? "time" : answered.fetch(position, "keyword")
          [ position, role == "filler" && keep.include?(query.tokens[position].singularize) ? "keyword" : role ]
        end
        matches = roles.keys.to_h { |position| [ position, roles[position] == "time" ? {} : label_matches(query.tokens[position], names) ] }
        words = roles.keys.select { |position| roles[position] == "keyword" && !query.exact_tokens.include?(query.tokens[position]) }
        words.each { |position| roles[position] = "label_term" if matches[position].any? }
        filler = words.select { |position| roles[position] == "keyword" && Search::Filler.word?(query.tokens[position], keep: keep) }
        Search::Filler.drop(filler, keyword_count: roles.values.count("keyword"), anchored: names.any? || !query.time_phrase.nil?,
          stopword: ->(position) { Search::Filler.stopword?(query.tokens[position]) })
          .each { |position| roles[position] = "filler" }
        label_terms = roles.keys.select { |position| roles[position] == "label_term" }
        sources = label_terms.to_h { |position| [ position, matches[position].keys.presence || names.keys ] }
        soft = (words & label_terms).select { |position| matches[position].values.all?(:prefix) }
        [ roles, sources, soft ]
      end

      # "category:billing" names "category" and "billing"; "needs_action"
      # names "needs_action", "needs", and "action". These key terms also
      # match by shared stem (see label_matches).
      STEM = 3

      def label_terms(storage_key)
        label, option = Search::Encoding.split_key(storage_key)
        [ label.split(":").last, option ].compact.flat_map { |name| [ name.downcase, *name.downcase.split(/[^\p{Alnum}]+/) ] }
          .reject(&:empty?).map(&:singularize)
      end

      # An option's display name (its search text, else its description) adds
      # its words minus stopwords: "p_17" shown as "Spiral writing tool" names
      # "spiral", "writing", and "tool". These
      # match exactly only: descriptions are prose, and a stem match on them
      # would swallow ordinary search words ("chat" against "charge").
      def name_terms(option_name)
        option_name.to_s.downcase.split(/[^\p{Alnum}]+/).reject { |word| word.empty? || STOPWORDS.include?(word) }.map(&:singularize)
      end

      def option_name(label, storage_key, tenant_key)
        return unless label.type == :choice

        label.option_names(tenant_key)[Search::Encoding.split_key(storage_key).last]
      end

      # {storage key => :exact or :prefix} for the applied labels `word`
      # names. "angry" names "anger": the same word ignoring plurals is
      # :exact; against a label or option key, two words of four letters or
      # more that share their first three letters are :prefix. Display-name
      # words match exactly only.
      def label_matches(word, names)
        word = word.singularize
        names.each_with_object({}) do |(key, (stems, terms)), matches|
          if terms.include?(word) || stems.include?(word)
            matches[key] = :exact
          elsif word.length > STEM && stems.any? { |term| term.length > STEM && word[0, STEM] == term[0, STEM] }
            matches[key] = :prefix
          end
        end
      end

      def intent_instructions(label)
        %(How does the search query use the label "#{label.key}" (#{label.description})?)
      end

      def instrument(model, tenant_key, started, **payload)
        Instrumentation.instrument("encode", { record_type: model.polymorphic_name, tenant_key: tenant_key,
          latency_ms: Instrumentation.elapsed_ms(started) }.merge(payload))
      end
    end
  end
end
