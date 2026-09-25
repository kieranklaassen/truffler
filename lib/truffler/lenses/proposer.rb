module Truffler
  module Lenses
    # Drafts lenses from query-miss clusters that passed the distinct-user
    # gate (R28, R29, R42). Proposals are stored as `proposed` and change
    # nothing until someone the policy allows activates them. The drafting
    # model sees only aggregated cluster terms and counts.
    class Proposer
      def self.propose(model, **options)
        new.propose(model, **options)
      end

      def initialize(drafter: Drafter.new, settings: Lenses.settings)
        @drafter = drafter
        @settings = settings
      end

      # tenant_key: one tenant's misses become tenant proposals;
      # Misses::ALL_TENANTS pools every tenant into app proposals.
      def propose(model, tenant_key:)
        return [] unless @settings.proposals

        model = Misses.resolve(model)
        scope = tenant_key == Misses::ALL_TENANTS ? Scope.app : Scope.tenant(tenant_key)
        Misses.clusters(model, tenant_key: tenant_key).filter_map do |cluster|
          proposal_digest = Canonical.digest(terms: cluster.terms.sort)
          next if existing?(model, scope, proposal_digest)

          draft = @drafter.draft(description_for(model, cluster), model: model, scope: scope, clusters: [ cluster ])
          create(draft, proposal_digest)
        end
      end

      private

      def existing?(model, scope, proposal_digest)
        Lens.for_model(model).where(scope_type: scope.type.to_s, tenant_key: scope.tenant_key, proposal_digest: proposal_digest).exists?
      end

      def description_for(model, cluster)
        "#{model.model_name.human.downcase.pluralize} about #{cluster.terms.to_sentence}"
      end

      def create(draft, proposal_digest)
        Lens.transaction do
          lens = Lens.build_from(draft, status: "proposed", origin: "proposal", proposal_digest: proposal_digest).tap(&:save!)
          lens.add_version!(draft, by: nil)
          Instrumentation.instrument(:lens_proposed, record_type: lens.record_type, tenant_key: lens.tenant_key, lens_id: lens.id)
          lens
        end
      end
    end
  end
end
