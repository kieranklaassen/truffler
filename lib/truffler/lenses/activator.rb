module Truffler
  module Lenses
    # Makes a draft, a draft version, or a proposed lens the active question
    # set of its lens (R41, R45). The lens row then carries the new questions
    # and fingerprint, which changes `Lenses.lens_fingerprints` for its scope
    # and so the scope's vocabulary version. Stored labels from the previous
    # version keep their old fingerprints: they keep serving searches and read
    # as stale until relabeled; LensBackfillJob relabels them.
    module Activator
      module_function

      # target: a Draft (creates the lens or adds a version to draft.lens), a
      # Version, or a Lens (activates its newest draft version).
      def activate(target, by:)
        version = case target
        when Draft then persist(target, by: by)
        when Version then target
        when Lens then target.draft_version || raise(InvalidLens, "lens #{target.id} has no draft version to activate")
        else raise ArgumentError, "cannot activate #{target.class.name}"
        end
        switch(version, by: by)
      end

      def persist(draft, by:)
        Policy.authorize!(by, draft.scope, model: draft.model)
        Validation.validate!(draft.questions, reused: draft.reused, declared: draft.model.truffler_definition.label_keys)
        Lens.transaction do
          lens = draft.lens || Lens.build_from(draft, status: "draft", creator_digest: Policy.digest_for(by)).tap(&:save!)
          lens.add_version!(draft, by: by)
        end
      end

      def switch(version, by:)
        lens = version.lens
        Policy.authorize!(by, lens.scope, model: lens.model)
        now = Time.current
        Lens.transaction do
          lens.versions.where(status: "active").where.not(id: version.id).update_all(status: "retired")
          version.update!(status: "active", activated_at: now, activated_by_digest: Policy.digest_for(by))
          lens.update!(status: "active", active_version: version, questions: version.questions,
            reused_keys: version.reused_keys, fingerprint: version.fingerprint, description: version.description,
            last_used_at: now)
        end
        Instrumentation.instrument(:lens_activated, record_type: lens.record_type, tenant_key: lens.tenant_key,
          lens_id: lens.id, lens_version_id: version.id, question_count: version.questions.to_h.size)
        Jobs::LensBackfillJob.perform_later(lens.id)
        lens
      end
    end
  end
end
