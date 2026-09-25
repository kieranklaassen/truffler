module Truffler
  module QueryEncoding
    # Adds the in-flight side of query encoding to U8's encoding cache: a
    # marker written with `unless_exist` so one job runs per query, and the
    # pending query payload the job reads (encrypted on encrypted models).
    # Both live only while the job is in flight; encodings and vectors are
    # written through `Search::EncodingCache` and never hold query text.
    class Cache
      delegate :key, :vector_key, :read, :write, :read_vector, :write_vector, to: :@encodings

      def initialize(store: Truffler.config.cache_store)
        @store = store
        @encodings = Search::EncodingCache.new(store: store)
      end

      def in_flight_key(cache_key)
        "#{cache_key}/in_flight"
      end

      def payload_key(cache_key)
        "#{cache_key}/payload"
      end

      # True when this caller took the marker, false when a job already holds it.
      def claim(cache_key, expires_in: IN_FLIGHT_TTL)
        @store.write(in_flight_key(cache_key), true, unless_exist: true, expires_in: expires_in).present?
      end

      def in_flight?(cache_key)
        @store.exist?(in_flight_key(cache_key))
      end

      def release(cache_key)
        @store.delete(payload_key(cache_key))
        @store.delete(in_flight_key(cache_key))
      end

      def encoded?(cache_key)
        @store.exist?(cache_key)
      end

      def read_encoding(cache_key, query)
        Search::Encoding.load(@store.read(cache_key), query || Search::Query.new(""))
      end

      # Returns false when the query cannot be stored safely: an encrypted
      # model without ActiveRecord encryption configured.
      def write_payload(cache_key, model, query, tenant_key:, user_key:, expires_in: IN_FLIGHT_TTL)
        encrypted = Misses.encrypted_model?(model)
        return false if encrypted && !Misses.encryption_configured?

        text = encrypted ? ActiveRecord::Encryption.encryptor.encrypt(query.normalized) : query.normalized
        @store.write(payload_key(cache_key), { "record_type" => model.polymorphic_name, "tenant_key" => tenant_key,
          "user_key" => user_key, "query" => text, "encrypted" => encrypted }, expires_in: expires_in)
        true
      end

      # {model:, query:, tenant_key:, user_key:} or nil once expired, released,
      # or undecryptable.
      def read_payload(cache_key)
        payload = @store.read(payload_key(cache_key))
        model = payload && payload["record_type"].safe_constantize
        return unless model.try(:truffler_definition)

        text = payload["encrypted"] ? ActiveRecord::Encryption.encryptor.decrypt(payload["query"]) : payload["query"]
        { model: model, query: Search::Query.new(text), tenant_key: payload["tenant_key"], user_key: payload["user_key"] }
      rescue ActiveRecord::Encryption::Errors::Base
        nil
      end
    end
  end
end
