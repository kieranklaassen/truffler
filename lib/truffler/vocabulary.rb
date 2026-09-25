module Truffler
  # A label's fingerprint is the SHA-256 of its canonical question plus the
  # pinned Jev model; the vocabulary version digests every fingerprint. A
  # stored label is stale when its fingerprint differs from the current one.
  #
  # A scope's vocabulary also holds its active lens labels (KTD21), so a lens
  # changes the version only where it applies. user_key is the searcher key
  # keystroke search hands the encoding hook; all_users: true is the labeling
  # scope, which includes every user's personal lenses in the tenant.
  class Vocabulary
    attr_reader :definition, :model

    def initialize(definition, model: Truffler.config.model)
      @definition = definition
      @model = model
    end

    # {key => LabelDefinition or Lenses::LensLabel}: the declared labels,
    # then the lens labels keyed "lens:<id>:<label>".
    def labels_for(tenant_key: nil, user_key: nil, all_users: false)
      lenses = Lenses.labels(definition.model, tenant_key: tenant_key, user_key: user_key, all_users: all_users)
      lenses.empty? ? definition.labels : definition.labels.merge(lenses)
    end

    def fingerprint(label_key, tenant_key: nil)
      Canonical.digest(question: definition.label(label_key).question(tenant_key), model: model)
    end

    def fingerprints(tenant_key: nil, user_key: nil, all_users: false)
      labels_for(tenant_key: tenant_key, user_key: user_key, all_users: all_users)
        .transform_values { |label| Canonical.digest(question: label.question(tenant_key), model: model) }
    end

    def version(tenant_key: nil, user_key: nil, all_users: false)
      Canonical.digest(fingerprints(tenant_key: tenant_key, user_key: user_key, all_users: all_users))
    end
  end
end
