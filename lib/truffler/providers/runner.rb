module Truffler
  module Providers
    # Calls the declared provider for one run, scoped to the searching
    # user's account, and stores exactly one terminal section state:
    # :results, :empty, or :unavailable. A cancelled run is left alone.
    class Runner
      def initialize(run, tenant_key:, user_key:)
        @run = run
        @tenant_key = tenant_key
        @user_key = user_key
      end

      def call
        return if cancelled?

        provider = Providers.declared(@run.model.truffler_definition)
        return unless provider

        started = Instrumentation.monotonic_ms
        state = search(provider)
        return if cancelled?

        @run.update_section(SECTION, state)
        instrument(state, started)
        state
      end

      private

      def search(provider)
        return Providers.state(provider, :unavailable, reason: :scope_mismatch) unless scope_matches?

        text = query_text
        return Providers.state(provider, :unavailable, reason: :no_query) if text.blank?

        results = Array.wrap(provider.search.call(text, tenant: @tenant_key, user: @user_key))
        results.empty? ? Providers.state(provider, :empty) : Providers.state(provider, :results, results: results)
      rescue StandardError => error
        Providers.state(provider, :unavailable, error_class: error.class.name)
      end

      # The job's keys come from the run's creator; a run that knows its own
      # keys must agree, so one account's provider never answers another's run.
      def scope_matches?
        %i[tenant_key user_key].all? do |key|
          !@run.respond_to?(key) || @run.public_send(key)&.to_s == instance_variable_get("@#{key}")&.to_s
        end
      end

      def query_text
        query = @run.query
        (query.respond_to?(:raw) ? query.raw : query.to_s).strip
      end

      def cancelled?
        @run.respond_to?(:cancelled?) && @run.cancelled?
      end

      def instrument(state, started)
        Instrumentation.instrument("provider_search", run_id: @run.id.to_s, record_type: @run.model.polymorphic_name,
          tenant_key: @tenant_key, user_key: @user_key, section: SECTION.to_s, status: state[:status],
          reason: state[:reason], result_count: Array(state[:results]).size, error_class: state[:error_class],
          latency_ms: (Instrumentation.monotonic_ms - started).round(2))
      end
    end
  end
end
