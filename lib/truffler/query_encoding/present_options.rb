module Truffler
  module QueryEncoding
    # With `config.skip_empty_options`, the choice options a tenant actually
    # has: storage keys with at least one label row at or above
    # `config.choice_min_probability` (above 0.0 when that is nil). Query
    # encoding offers Jev only these, so it cannot pick "Source: email" in a
    # tenant with no email sources.
    #
    # The set is digested into the encoding cache key, so encodings refresh
    # when an option appears. It is read through the cache store for TTL, so
    # a keystroke stays one SELECT; a new option reaches query encoding (and
    # the cache key) within TTL.
    class PresentOptions
      TTL = 5.minutes

      def initialize(store: Truffler.config.cache_store)
        @store = store
      end

      def self.enabled?
        Truffler.config.skip_empty_options == true
      end

      # The present storage keys among `labels`' choice options, or nil when
      # skip_empty_options is off.
      def keys(model, labels, tenant_key:)
        return unless self.class.enabled?

        candidates = labels.values.select { |label| label.type == :choice }.flat_map { |label| label.storage_keys(tenant_key) }.sort
        return Set.new if candidates.empty?

        min = Truffler.config.choice_min_probability
        cache_key = "truffler/present_options/#{Canonical.digest(record_type: model.polymorphic_name, tenant_key: tenant_key&.to_s,
          keys: candidates, min: min)}"
        Set.new(@store.fetch(cache_key, expires_in: TTL) { present(model, candidates, tenant_key, min) })
      end

      # A label's options narrowed to `present` (all of them when nil).
      def self.options(label, tenant_key, present)
        options = label.options(tenant_key)
        present ? options.select { |option, _| present.include?("#{label.key}:#{option}") } : options
      end

      private

      def present(model, candidates, tenant_key, min)
        rows = Records::Label.where(record_type: model.polymorphic_name, label_key: candidates)
        rows = rows.where(tenant_key: tenant_key.to_s) if model.truffler_definition.scoped?
        rows = min ? rows.where(value: min..) : rows.where(Records::Label.arel_table[:value].gt(0.0))
        rows.distinct.pluck(:label_key).sort
      end
    end
  end
end
