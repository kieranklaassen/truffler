module Truffler
  module Providers
    # Decides whether the provider backup runs for one explicit action and,
    # when it does, marks the section pending and enqueues the search. Local
    # sections are never touched.
    class Backup
      def initialize(run, query:, tenant_key:, user_key:, local_result: nil)
        @run = run
        @query = Search::Query.wrap(query)
        @tenant_key = tenant_key&.to_s
        @user_key = user_key&.to_s
        @local_result = local_result
      end

      def start
        provider = Providers.declared(definition)
        return unless provider

        reason = self.reason
        instrument(reason)
        return unless reason

        @run.update_section(SECTION, Providers.state(provider, :pending))
        Jobs::ProviderSearchJob.perform_later(@run.id.to_s, @tenant_key, @user_key)
        reason
      end

      def reason
        return if @query.blank?
        return :exact_text if @query.exact_text?

        :weak_local if weak_local?
      end

      private

      def definition
        @run.model.truffler_definition
      end

      def weak_local?
        return @local_result.local_weak? if @local_result
        return @run.local_weak? if @run.respond_to?(:local_weak?)
        unless @run.respond_to?(:candidate_ids)
          raise ArgumentError, "Providers.start needs local_result: or a run that responds to local_weak? or candidate_ids"
        end

        Array(@run.candidate_ids).size < definition.weak_below
      end

      def instrument(reason)
        Instrumentation.instrument("provider_start", run_id: @run.id.to_s, record_type: @run.model.polymorphic_name,
          tenant_key: @tenant_key, user_key: @user_key, section: SECTION.to_s, outcome: reason ? :enqueued : :skipped,
          reason: reason)
      end
    end
  end
end
