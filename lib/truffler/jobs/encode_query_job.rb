module Truffler
  module Jobs
    # Encodes one pending query at encode priority. The only argument is the
    # cache key; the query itself waits in the cache (encrypted on encrypted
    # models). A Jev failure is dropped: the in-flight marker is released,
    # so the next keystroke of that query prefetches again.
    class EncodeQueryJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      discard_on ClientError, IncompleteAnswers

      def perform(cache_key)
        QueryEncoding::Encoder.new.encode(cache_key)
      end
    end
  end
end
