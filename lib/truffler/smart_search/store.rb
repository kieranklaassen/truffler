module Truffler
  module SmartSearch
    # Where Smart runs live (KTD11): the configured cache store, keyed by run
    # id, every entry expiring with the run. A run is split across keys so
    # concurrent chunk jobs never read-modify-write one entry:
    #
    #   truffler/smart/run/<id>                 immutable core (query, snapshot)
    #   truffler/smart/run/<id>/status          paused or cancelled, when set
    #   truffler/smart/run/<id>/plan            filtered candidates and chunks
    #   truffler/smart/run/<id>/chunk/<n>       one chunk's scores and arrival seq
    #   truffler/smart/run/<id>/seq             arrival counter
    #   truffler/smart/run/<id>/section/<name>  host sections such as provider
    #   truffler/smart/generation/<digest>      the current run per searcher
    #
    # On encrypted models the query is encrypted with a MessageEncryptor
    # keyed from `secret_key_base` (R5, R29). Jobs carry only the run id.
    class Store
      PREFIX = "truffler/smart".freeze

      attr_reader :cache

      def initialize(cache: Truffler.config.cache_store, ttl: Truffler.config.smart_run_ttl)
        @cache = cache
        @ttl = ttl
      end

      def read(run_id, part = nil)
        @cache.read(key(run_id, part))
      end

      def write(run_id, part, value)
        @cache.write(key(run_id, part), value, expires_in: @ttl)
      end

      def delete(run_id, part)
        @cache.delete(key(run_id, part))
      end

      # Monotonic arrival order for chunk results; falls back to the clock
      # on a store that cannot count.
      def next_seq(run_id)
        @cache.increment(key(run_id, "seq"), 1, expires_in: @ttl) || (Time.now.to_r * 1_000_000).to_i
      end

      # Makes `run_id` the current run for the searcher and returns the run
      # id it replaced, if any (KTD11 generation token).
      def supersede(record_type, tenant_key, user_key, surface, run_id)
        key = generation_key(record_type, tenant_key, user_key, surface)
        previous = @cache.read(key)
        @cache.write(key, run_id, expires_in: @ttl)
        previous unless previous == run_id
      end

      def current_run_id(record_type, tenant_key, user_key, surface)
        @cache.read(generation_key(record_type, tenant_key, user_key, surface))
      end

      def seal(model, text)
        return { "query" => text, "encrypted" => false } unless Misses.encrypted_model?(model)

        { "query" => encryptor.encrypt_and_sign(text, purpose: :truffler_smart_query), "encrypted" => true }
      end

      def unseal(core)
        return core["query"] unless core["encrypted"]

        encryptor.decrypt_and_verify(core["query"], purpose: :truffler_smart_query)
      end

      private

      def key(run_id, part)
        [ PREFIX, "run", run_id, part ].compact.join("/")
      end

      def generation_key(record_type, tenant_key, user_key, surface)
        "#{PREFIX}/generation/#{Canonical.digest([ record_type, tenant_key, user_key, surface ])}"
      end

      def encryptor
        @encryptor ||= begin
          secret = ActiveSupport::KeyGenerator.new(Truffler.config.secret_key_base, iterations: 1_000)
            .generate_key("truffler/smart-run-query", 32)
          ActiveSupport::MessageEncryptor.new(secret, cipher: "aes-256-gcm")
        end
      end
    end
  end
end
