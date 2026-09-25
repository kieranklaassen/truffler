module Truffler
  # The query miss log (R28, R29). The query encoder calls `hook` when an
  # encoding matched no label; developers and the lens proposer read only
  # aggregated clusters that passed the distinct-user gate.
  module Misses
    ALL_TENANTS = :all
    MAX_ROWS = 10_000

    Cluster = Data.define(:terms, :query_count, :distinct_users)

    module_function

    # The callable the encoder invokes: `call(model, tenant_key:, user_key:, query:)`.
    def hook
      @hook ||= Recorder.new
    end

    def record(model, tenant_key:, user_key:, query:)
      hook.call(model, tenant_key: tenant_key, user_key: user_key, query: query)
    end

    # Clusters of normalized non-filler terms with their query and distinct-user
    # counts, newest misses within the retention window only. Every exposed term
    # was itself seen from at least the gate's number of users. The gate can be
    # raised per call but never lowered below `miss_min_distinct_users`.
    def clusters(record_type, tenant_key:, min_distinct_users: nil)
      model = resolve(record_type)
      texts = entries(model, tenant_key: tenant_key).filter_map { |text, user, _| [ text, user ] if text }
      Clusterer.new(model, min_distinct_users: gate(min_distinct_users)).clusters(texts)
    end

    # [normalized query or nil, user digest, query digest] per retained miss.
    def entries(model, tenant_key:)
      scope = Records::QueryMiss.for_model(model).retained
      scope = scope.where(tenant_key: tenant_key) unless tenant_key == ALL_TENANTS
      scope.order(created_at: :desc).limit(MAX_ROWS).map { |miss| [ miss.query, miss.user_digest, miss.query_digest ] }
    end

    def gate(min_distinct_users)
      [ min_distinct_users.to_i, Truffler.config.miss_min_distinct_users.to_i, 1 ].max
    end

    def normalize(query)
      Search::Query.normalize(query)
    end

    def digest(purpose, value)
      OpenSSL::HMAC.hexdigest("SHA256", Truffler.config.secret_key_base, "truffler/miss/#{purpose}/#{value}")
    end

    def encrypted_model?(model)
      Array(model.try(:encrypted_attributes)).any?
    end

    def encryption_configured?
      config = ActiveRecord::Encryption.config
      config.has_primary_key? && config.has_key_derivation_salt?
    end

    # Text stored about an encrypted model is AR-encryption ciphertext when
    # that is configured, and nothing otherwise (R29).
    def seal(model, text)
      return text if text.nil? || !encrypted_model?(model)

      ActiveRecord::Encryption.encryptor.encrypt(text) if encryption_configured?
    end

    def unseal(model, stored)
      return stored if stored.nil? || !encrypted_model?(model)

      ActiveRecord::Encryption.encryptor.decrypt(stored)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    def resolve(record_type)
      model = record_type.is_a?(Class) ? record_type : record_type.to_s.safe_constantize
      raise ArgumentError, "#{record_type} is not a truffler model" unless model.try(:truffler_definition)

      model
    end
  end
end
