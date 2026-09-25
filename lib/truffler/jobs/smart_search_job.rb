module Truffler
  module Jobs
    # Plans one Smart run: budget, encoding wait, filters, chunk fan-out.
    # The only argument is the run id; the query waits in the cache
    # (encrypted on encrypted models).
    class SmartSearchJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform(run_id)
        SmartSearch::Dispatcher.new.call(SmartSearch::Run.find(run_id))
      end
    end
  end
end
