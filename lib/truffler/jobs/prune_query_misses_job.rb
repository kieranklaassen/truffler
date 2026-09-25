module Truffler
  module Jobs
    # Enforces the miss log retention window (R29). Takes no arguments; hosts
    # schedule it, for example daily.
    class PruneQueryMissesJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform
        deleted = Records::QueryMiss.expired.in_batches(of: 1_000).delete_all
        Instrumentation.instrument("miss_prune", deleted_count: deleted)
        deleted
      end
    end
  end
end
