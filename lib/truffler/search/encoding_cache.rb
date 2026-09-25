module Truffler
  module Search
    # Where keystroke search finds query encodings and query vectors (R12,
    # R15). Keys digest the model, the normalized query, and the vocabulary's
    # encoding version (labeling fingerprints plus descriptions and option
    # search texts), plus the tenant when the vocabulary has per-tenant choices.
    # Values hold decisions and floats, never query text. Encoding keys use
    # the searcher's vocabulary version, which holds the lenses that searcher
    # can see (KTD21), so a personal lens's encoding is never shared; query
    # vectors do not depend on lenses and stay keyed per tenant.
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

      def key(model, query, tenant_key:, user_key: nil)
        "truffler/enc/#{digest(model, query, tenant_key, user_key)}"
      end

      def vector_key(model, query, tenant_key:)
        "truffler/vec/#{digest(model, query, tenant_key, nil)}"
      end

      def read(model, query, tenant_key:, user_key: nil)
        query = Query.wrap(query)
        Encoding.load(@store.read(key(model, query, tenant_key: tenant_key, user_key: user_key)), query)
      end

      def write(model, query, encoding, tenant_key:, user_key: nil, expires_in: TTL)
        query = Query.wrap(query)
        @store.write(key(model, query, tenant_key: tenant_key, user_key: user_key), encoding.dump(query), expires_in: expires_in)
      end

      def read_vector(model, query, tenant_key:)
        @store.read(vector_key(model, Query.wrap(query), tenant_key: tenant_key))&.map(&:to_f)
      end

      def write_vector(model, query, vector, tenant_key:, expires_in: TTL)
        @store.write(vector_key(model, Query.wrap(query), tenant_key: tenant_key), vector.map(&:to_f), expires_in: expires_in)
      end

      def prefetch(model, query, tenant_key:, user_key:)
        hook = Truffler.config.encoding_prefetch
        return false unless hook

        query = Query.wrap(query)
        hook.call(model, query, cache_key: key(model, query, tenant_key: tenant_key, user_key: user_key), tenant_key: tenant_key,
          user_key: user_key).present?
      end

      private

      def digest(model, query, tenant_key, user_key)
        definition = model.truffler_definition
        tenant = tenant_key&.to_s if definition.per_tenant_vocabulary?
        version = definition.vocabulary.encoding_version(tenant_key: tenant_key&.to_s, user_key: user_key)
        parts = { record_type: model.polymorphic_name, query: query.normalized, vocabulary_version: version, tenant_key: tenant }
        present = present_options(model, tenant_key, user_key)
        Canonical.digest(present ? parts.merge(present_options: Canonical.digest(present.to_a.sort)) : parts)
      end

      # With skip_empty_options, the tenant's present choice options (see
      # QueryEncoding::PresentOptions), so an encoding refreshes when one appears.
      def present_options(model, tenant_key, user_key)
        return unless QueryEncoding::PresentOptions.enabled?

        labels = model.truffler_definition.vocabulary.labels_for(tenant_key: tenant_key&.to_s, user_key: user_key)
        QueryEncoding::PresentOptions.new.keys(model, labels, tenant_key: tenant_key&.to_s)
      end
    end
  end
end
