module Truffler
  module Search
    # Where keystroke search finds query encodings and query vectors (R12,
    # R15). Keys digest the model, the normalized query, and the vocabulary
    # version, plus the tenant when the vocabulary has per-tenant choices.
    # Values hold decisions and floats, never query text.
    #
    # On a miss, search calls `prefetch`, which hands off to
    # `config.encoding_prefetch` (the query encoder, U9). The hook is called
    # as `call(model, query, cache_key:, tenant_key:, user_key:)` and returns
    # truthy when an encoding is now in flight. Without a hook nothing is
    # encoded and the encoding status reads `:none`.
    class EncodingCache
      TTL = 7.days

      def initialize(store: Truffler.config.cache_store)
        @store = store
      end

      def key(model, query, tenant_key:)
        "truffler/enc/#{digest(model, query, tenant_key)}"
      end

      def vector_key(model, query, tenant_key:)
        "truffler/vec/#{digest(model, query, tenant_key)}"
      end

      def read(model, query, tenant_key:)
        query = cast(query)
        Encoding.load(@store.read(key(model, query, tenant_key: tenant_key)), query)
      end

      def write(model, query, encoding, tenant_key:, expires_in: TTL)
        query = cast(query)
        @store.write(key(model, query, tenant_key: tenant_key), encoding.dump(query), expires_in: expires_in)
      end

      def read_vector(model, query, tenant_key:)
        @store.read(vector_key(model, cast(query), tenant_key: tenant_key))&.map(&:to_f)
      end

      def write_vector(model, query, vector, tenant_key:, expires_in: TTL)
        @store.write(vector_key(model, cast(query), tenant_key: tenant_key), vector.map(&:to_f), expires_in: expires_in)
      end

      def prefetch(model, query, tenant_key:, user_key:)
        hook = Truffler.config.encoding_prefetch
        return false unless hook

        query = cast(query)
        hook.call(model, query, cache_key: key(model, query, tenant_key: tenant_key), tenant_key: tenant_key, user_key: user_key).present?
      end

      private

      def cast(query)
        query.is_a?(Query) ? query : Query.new(query)
      end

      def digest(model, query, tenant_key)
        definition = model.truffler_definition
        tenant = tenant_key&.to_s if definition.per_tenant_vocabulary?
        Canonical.digest(record_type: model.polymorphic_name, query: query.normalized,
          vocabulary_version: definition.vocabulary.version(tenant_key: tenant), tenant_key: tenant)
      end
    end
  end
end
