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

    # Active lenses whose questions records of one tenant are labeled with:
    # app lenses, the tenant's lenses, and every user's personal lenses in
    # that tenant. Personal answers are stored per record like any other,
    # and only their owner's searches can see them.
    def labeling_lenses(model, tenant_key:)
      lenses = Lens.active.where(record_type: model.polymorphic_name)
      lenses.where(scope_type: "app").or(lenses.where(scope_type: %w[tenant user], tenant_key: tenant_key&.to_s)).order(:id).to_a
    end

    # {"lens:<id>:<label>" => LensLabel} visible to one searcher, or with
    # all_users: true, every label records of the tenant are labeled with.
    def labels(model, tenant_key:, user_key: nil, all_users: false)
      rows = active_rows(model, tenant_key)
      unless all_users
        personal = rows.select { |row| row["scope_type"] == "user" }
        owner = digest(user_key) if personal.any? && user_key.present?
        rows -= personal.reject { |row| owner && row["scope_key"] == owner }
      end
      rows.each_with_object({}) do |row, all|
        row["questions"].each do |label, question|
          lens_label = LensLabel.new(row["id"], label, question)
          all[lens_label.key] = lens_label
        end
      end
    end

    ACTIVE_TTL = 1.minute

    # The labeling lenses of one tenant from the cache store, so keystroke
    # search computes its vocabulary version without a query (R12). Any lens
    # change bumps a per-model generation; the TTL bounds staleness for
    # per-process cache stores.
    def active_rows(model, tenant_key)
      cache = Truffler.config.cache_store
      generation = cache.read(generation_key(model.polymorphic_name)) || "0"
      key = "truffler/lenses/#{model.polymorphic_name}/#{generation}/#{Canonical.digest(tenant_key.to_s)}"
      cache.fetch(key, expires_in: ACTIVE_TTL) do
        labeling_lenses(model, tenant_key: tenant_key).map do |lens|
          { "id" => lens.id, "scope_type" => lens.scope_type, "scope_key" => lens.scope_key, "questions" => lens.questions.to_h }
        end
      end
    end

    def changed!(record_type)
      Truffler.config.cache_store.write(generation_key(record_type), SecureRandom.hex(8))
    end

    def generation_key(record_type)
      "truffler/lenses/#{record_type}/generation"
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
      Misses.seal(model, text)
    end

    def unseal(model, stored)
      Misses.unseal(model, stored)
    end
  end
end
