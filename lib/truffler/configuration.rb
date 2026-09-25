module Truffler
  class Configuration
    DEFAULT_REQUESTS_PER_MINUTE = 1_200
    DEFAULT_PRIORITY_CEILINGS = { live: 1.0, encode: 0.9, rerank: 0.75, backfill: 0.5 }.freeze
    DEFAULT_USER_CAPS = { encode: 30, rerank: 10 }.freeze

    attr_accessor :model, :cost_per_million_tokens, :requests_per_minute, :headroom, :priority_ceilings,
      :user_caps, :tenant_live_cap, :max_wait, :batch_size, :grouping_window, :max_attempts,
      :max_field_chars, :request_token_budget, :max_questions_per_request, :queue_name,
      :embedder, :encryptor, :backfill_spend_cap, :resume_pending_after
    attr_writer :client, :cache_store, :logger
    attr_accessor :miss_retention, :miss_min_distinct_users
    attr_writer :secret_key_base
    attr_accessor :vector_store, :embedding_cost_per_million_tokens

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
      @backfill_spend_cap = nil
      @resume_pending_after = 5.minutes
      @vector_store = :auto
      @embedding_cost_per_million_tokens = 0.02
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
