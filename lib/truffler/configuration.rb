module Truffler
  class Configuration
    DEFAULT_REQUESTS_PER_MINUTE = 1_200
    DEFAULT_PRIORITY_CEILINGS = { live: 1.0, encode: 0.9, rerank: 0.75, backfill: 0.5 }.freeze
    DEFAULT_USER_CAPS = { encode: 30, rerank: 10 }.freeze
    DEFAULT_BACKFILL_SPEND_CAP = 5.0

    attr_accessor :model, :cost_per_million_tokens, :requests_per_minute, :headroom, :priority_ceilings,
      :user_caps, :tenant_live_cap, :max_wait, :batch_size, :grouping_window, :max_attempts,
      :max_field_chars, :request_token_budget, :max_questions_per_request, :queue_name,
      :embedder, :encryptor, :backfill_spend_cap, :resume_pending_after
    attr_writer :client, :cache_store, :logger
    attr_accessor :miss_retention, :miss_min_distinct_users
    attr_writer :secret_key_base
    attr_accessor :vector_store, :embedding_cost_per_million_tokens
    attr_accessor :encoding_prefetch
    attr_reader :lenses
    attr_accessor :encoding_deadline, :rerank_depth, :rerank_chunk_size, :rerank_max_field_chars, :smart_thresholds,
      :smart_run_ttl, :smart_candidate_pool, :broadcaster
    # Generic nouns that are never required keywords on their own (Search::Filler).
    attr_accessor :filler_words
    # ->(model, tenant_key) { true/false } for tenant-scoped models; nil indexes every tenant.
    attr_accessor :tenant_enabled
    # :tenant (a spend ledger per tenant for scoped models) or :app (one per model).
    attr_accessor :backfill_spend_cap_scope
    # Choice options below this probability store no row and read as 0.0 (nil stores every option).
    attr_accessor :choice_min_probability
    # Query encoding omits choice options the tenant has no label row for (QueryEncoding::PresentOptions).
    attr_accessor :skip_empty_options

    def initialize(env: ENV)
      @model = "jev-latest"
      @cost_per_million_tokens = 0.042
      @requests_per_minute = Integer(env["TYPESAFE_REQUESTS_PER_MINUTE"].presence || DEFAULT_REQUESTS_PER_MINUTE)
      @headroom = 0.25
      @priority_ceilings = DEFAULT_PRIORITY_CEILINGS.dup
      @user_caps = DEFAULT_USER_CAPS.dup
      @tenant_live_cap = 120
      @max_wait = 5.0
      @batch_size = 10
      @grouping_window = 0
      @max_attempts = 5
      @max_field_chars = 4_000
      @request_token_budget = 48_000
      @max_questions_per_request = 200
      @queue_name = :default
      @miss_retention = 30.days
      @miss_min_distinct_users = 5
      @backfill_spend_cap = DEFAULT_BACKFILL_SPEND_CAP
      @resume_pending_after = 5.minutes
      @vector_store = :auto
      @embedding_cost_per_million_tokens = 0.02
      @lenses = Lenses::Settings.new
      @encoding_prefetch = QueryEncoding::Prefetch.new
      @encoding_deadline = 1.0
      @rerank_depth = 30
      @rerank_chunk_size = 10
      @rerank_max_field_chars = 1_200
      @smart_thresholds = { strong: 0.70, possible: 0.35 }
      @smart_run_ttl = 15.minutes
      @smart_candidate_pool = 200
      @broadcaster = nil
      @filler_words = Search::Filler::DEFAULT_WORDS.dup
      @tenant_enabled = nil
      @backfill_spend_cap_scope = :tenant
      @choice_min_probability = 0.05
      @skip_empty_options = false
    end

    def client
      @client ||= Clients::RubyLLMTypeSafe.new
    end

    def cache_store
      @cache_store || rails_cache || (@fallback_cache ||= ActiveSupport::Cache::MemoryStore.new)
    end

    def logger
      @logger || rails_logger || (@fallback_logger ||= ActiveSupport::Logger.new(nil))
    end

    def cost_for(tokens)
      tokens.to_i * cost_per_million_tokens / 1_000_000.0
    end

    def secret_key_base
      @secret_key_base.presence || rails_secret_key_base.presence ||
        raise(Error, "Truffler needs config.secret_key_base (or a Rails secret_key_base) to digest query misses")
    end

    private

    def rails_cache
      Rails.cache if defined?(Rails) && Rails.respond_to?(:cache)
    end

    def rails_logger
      Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
    end

    def rails_secret_key_base
      Rails.application&.secret_key_base if defined?(Rails) && Rails.respond_to?(:application)
    end
  end
end
