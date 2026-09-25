module Truffler
  module Instrumentation
    module_function

    def instrument(event, payload = {})
      ActiveSupport::Notifications.instrument("truffler.#{event}", Redaction.safe(payload))
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end

    def elapsed_ms(started)
      (monotonic_ms - started).round(2)
    end
  end
end
