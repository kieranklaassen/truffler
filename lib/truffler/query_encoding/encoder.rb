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
    # vocabulary rides along in `state["labels"]` so a token question can
    # tell a word that names a label from text to match.
    #
    # Jev's word roles are then reconciled locally: a keyword that names a
    # label the query applies (its key, a word of its key, or the chosen
    # option, ignoring case and plurals) becomes a label term, and a common
    # stopword becomes filler.
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
      STOPWORDS = %w[
        a about all an and any are at be by for from have i in is it me my now of on or our please so some that the their
        them there they this to up us was we what when where which who why with you your
      ].to_set.freeze

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

        words = query.tokens.each_with_index.reject { |token, _| query.exact_tokens.include?(token) }
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
        terms = []
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
          terms.concat(label_terms(key))
        end

        query = Search::Query.new(request.state["query"])
        roles = reconcile(query, request.token_ids.transform_values { |id| answers.choice(id) }, terms.uniq)
        keyword_tokens = query.tokens.each_index.filter_map { |position| query.tokens[position] if roles[position] == "keyword" }
        label_term_tokens = query.tokens.each_index.filter_map { |position| query.tokens[position] if roles[position] == "label_term" }
        Search::Encoding.new(filters: filters, boosts: boosts, intent_vector: intent, keyword_tokens: keyword_tokens,
          label_term_tokens: label_term_tokens)
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
          entry["options"] = label.options(tenant_key).keys if label.type == :choice
          entry
        end
      end

      # {position => role} for every token. Exact tokens and unasked words
      # are keywords; a keyword naming an applied label becomes a label term;
      # stopwords become filler unless they are all that would be left of an
      # encoding that applies nothing.
      def reconcile(query, answered, terms)
        roles = query.tokens.each_index.to_h { |position| [ position, answered.fetch(position, "keyword") ] }
        words = roles.keys.select { |position| roles[position] == "keyword" && !query.exact_tokens.include?(query.tokens[position]) }
        words.each { |position| roles[position] = "label_term" if names_label?(query.tokens[position], terms) }
        stopwords = words.select { |position| roles[position] == "keyword" && STOPWORDS.include?(query.tokens[position]) }
        return roles if terms.empty? && roles.values.count("keyword") == stopwords.size

        stopwords.each { |position| roles[position] = "filler" }
        roles
      end

      # "category:billing" names "category" and "billing"; "needs_action"
      # names "needs_action", "needs", and "action".
      def label_terms(storage_key)
        label, option = Search::Encoding.split_key(storage_key)
        [ label.split(":").last, option ].compact.flat_map { |name| [ name.downcase, *name.downcase.split(/[^\p{Alnum}]+/) ] }
          .reject(&:empty?).map(&:singularize)
      end

      def names_label?(word, terms)
        terms.include?(word.singularize)
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
