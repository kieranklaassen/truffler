module Truffler
  # Lenses (KTD21): LLM-drafted label questions stored as vocabulary
  # extensions. Their answers live in `truffler_labels` under
  # "lens:<lens_id>:<label>", so filters, label vectors, staleness, and
  # backfill treat them like declared labels.
  #
  # `visible_questions` and `lens_fingerprints` are the seam the vocabulary
  # and query encoding plug into: the active lens questions one searcher can
  # see, and a digest that changes whenever that set changes.
  module Lenses
    KEY_PREFIX = "lens".freeze

    Visibility = Data.define(:questions, :fingerprints, :lens_fingerprints, :lens_ids)

    module_function

    def settings
      Truffler.config.lenses
    end

    def storage_prefix(lens_id)
      "#{KEY_PREFIX}:#{lens_id}:"
    end

    def label_key(lens_id, label)
      "#{storage_prefix(lens_id)}#{label}"
    end

    # Active lenses of this model visible to one searcher: app lenses, the
    # tenant's lenses, and the user's own lenses in that tenant.
    def visible_lenses(model, tenant_key:, user_key: nil, user_digest: nil)
      user_digest ||= digest(user_key) if user_key.present?
      tenant_key = tenant_key&.to_s
      lenses = Lens.active.where(record_type: model.polymorphic_name)
      visible = lenses.where(scope_type: "app").or(lenses.where(scope_type: "tenant", tenant_key: tenant_key))
      visible = visible.or(lenses.where(scope_type: "user", tenant_key: tenant_key, scope_key: user_digest)) if user_digest
      visible.order(:id).to_a
    end

    def visible(model, tenant_key:, user_key: nil)
      lenses = visible_lenses(model, tenant_key: tenant_key, user_key: user_key)
      questions = lenses.each_with_object({}) { |lens, all| all.merge!(lens.storage_questions) }
      fingerprints = questions.transform_values { |question| fingerprint(question) }
      Visibility.new(questions: questions, fingerprints: fingerprints,
        lens_fingerprints: (Canonical.digest(fingerprints) if fingerprints.any?), lens_ids: lenses.map(&:id))
    end

    # {"lens:<id>:<label>" => wire-shape question} for active visible lenses.
    def visible_questions(model, tenant_key:, user_key: nil)
      visible(model, tenant_key: tenant_key, user_key: user_key).questions
    end

    # A digest of every visible lens label's fingerprint, or nil when no lens
    # is visible, so a vocabulary without lenses keeps its version.
    def lens_fingerprints(model, tenant_key:, user_key: nil)
      visible(model, tenant_key: tenant_key, user_key: user_key).lens_fingerprints
    end

    # The same formula as Vocabulary#fingerprint: canonical question plus the
    # pinned Jev model.
    def fingerprint(question, model: Truffler.config.model)
      Canonical.digest(question: question, model: model)
    end

    # Counts a search that used these lenses, which keeps them from expiring
    # and tells developers which lenses to promote (R43).
    def record_usage(lens_ids, now: Time.current)
      return 0 if lens_ids.blank?

      Lens.where(id: lens_ids).update_all([ "usage_count = usage_count + 1, last_used_at = ?, updated_at = ?", now, now ])
    end

    def digest(user_key)
      OpenSSL::HMAC.hexdigest("SHA256", Truffler.config.secret_key_base, "truffler/lens/user/#{user_key}")
    end

    # Descriptions on encrypted models follow the miss-log rules (R29, R44):
    # AR-encryption ciphertext when it is configured, nothing otherwise.
    def seal(model, text)
      return text if text.nil? || !Misses.encrypted_model?(model)

      ActiveRecord::Encryption.encryptor.encrypt(text) if Misses.encryption_configured?
    end

    def unseal(model, stored)
      return stored if stored.nil? || !Misses.encrypted_model?(model)

      ActiveRecord::Encryption.encryptor.decrypt(stored)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end
  end
end
