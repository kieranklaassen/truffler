module Truffler
  module QueryEncoding
    # The default `config.encoding_prefetch`. Called by keystroke search on a
    # cache miss; enqueues one `EncodeQueryJob(cache_key)` per in-flight window
    # and returns true while an encoding is in flight. It never calls Jev.
    class Prefetch
      def initialize(cache: nil)
        @cache = cache
      end

      def call(model, query, cache_key:, tenant_key:, user_key:)
        cache = @cache || Cache.new
        return false unless work?(cache, model, query, cache_key, tenant_key)
        return true unless cache.claim(cache_key)

        unless cache.write_payload(cache_key, model, query, tenant_key: tenant_key, user_key: user_key)
          cache.release(cache_key)
          return false
        end

        Jobs::EncodeQueryJob.perform_later(cache_key)
        true
      end

      private

      def work?(cache, model, query, cache_key, tenant_key)
        definition = model.truffler_definition
        (definition.labels.any? && !cache.encoded?(cache_key)) ||
          (Embeddings.managed?(definition) && cache.read_vector(model, query, tenant_key: tenant_key).nil?)
      end
    end
  end
end
