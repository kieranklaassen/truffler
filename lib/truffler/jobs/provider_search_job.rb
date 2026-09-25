module Truffler
  module Jobs
    # Runs the provider backup search for one Smart run (R19). Arguments are
    # the run id plus the searching tenant and user keys; the query text is
    # read from the run, never carried in the job. See Truffler::Providers for
    # the run interface. An expired run is a no-op.
    class ProviderSearchJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform(run_id, tenant_key, user_key)
        run = Providers.find_run(run_id)
        return unless run

        Providers::Runner.new(run, tenant_key: tenant_key, user_key: user_key).call
      end
    end
  end
end
