module Truffler
  module Jobs
    # Reranks one chunk of a Smart run and pings the searcher. Arguments are
    # the run id and the chunk index only. A Jev failure marks the chunk
    # failed so its buckets still resolve; it is not retried.
    class RerankChunkJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform(run_id, index)
        SmartSearch::Reranker.new.call(SmartSearch::Run.find(run_id), Integer(index))
      end
    end
  end
end
