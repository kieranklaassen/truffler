module Truffler
  module Jobs
    # Expires lenses unused for `config.lenses.expire_after` (R43). Takes no
    # arguments; hosts schedule it, for example daily.
    class ExpireLensesJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      def perform
        expired = Lenses::Lens.expire_unused!
        Instrumentation.instrument("lens_expire", expired_count: expired)
        expired
      end
    end
  end
end
