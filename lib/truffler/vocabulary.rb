module Truffler
  # A label's fingerprint is the SHA-256 of its canonical question plus the
  # pinned Jev model; the vocabulary version digests every fingerprint. A
  # stored label is stale when its fingerprint differs from the current one.
  class Vocabulary
    attr_reader :definition, :model

    def initialize(definition, model: Truffler.config.model)
      @definition = definition
      @model = model
    end

    def fingerprint(label_key, tenant_key: nil)
      Canonical.digest(question: definition.label(label_key).question(tenant_key), model: model)
    end

    def fingerprints(tenant_key: nil)
      definition.label_keys.index_with { |key| fingerprint(key, tenant_key: tenant_key) }
    end

    def version(tenant_key: nil)
      Canonical.digest(fingerprints(tenant_key: tenant_key))
    end
  end
end
