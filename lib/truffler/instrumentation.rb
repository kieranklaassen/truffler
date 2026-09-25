module Truffler
  module Instrumentation
    module_function

    def instrument(event, payload = {})
      ActiveSupport::Notifications.instrument("truffler.#{event}", Redaction.safe(payload))
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
