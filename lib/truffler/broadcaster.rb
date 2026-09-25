module Truffler
  # The data-free Action Cable ping of KTD13: `{run_id, section, changed_at}`
  # on `truffler:<user_key>`. Hosts answer it with an Inertia partial reload
  # of the named prop (`smart`, `provider`), so no result data rides the
  # socket (R27). A failed broadcast is reported and swallowed: a ping is a
  # hint, and the work that triggered it must not fail with it.
  #
  # `config.broadcaster` may be any object responding to
  # `broadcast(stream, payload)`; the default is `ActionCable.server` when
  # Action Cable is loaded, otherwise pings are dropped.
  module Broadcaster
    module_function

    def stream(user_key)
      "truffler:#{user_key}"
    end

    # True when a ping was handed to the server.
    def ping(user_key, run_id:, section:)
      return false if user_key.blank?

      target = server
      return false unless target

      target.broadcast(stream(user_key), { run_id: run_id, section: section.to_s, changed_at: Time.current.iso8601(6) })
      true
    rescue StandardError => error
      report(error, run_id: run_id, section: section)
      false
    end

    def server
      Truffler.config.broadcaster || (ActionCable.server if defined?(ActionCable) && ActionCable.respond_to?(:server))
    end

    def report(error, run_id:, section:)
      Instrumentation.instrument(:broadcast_failed, run_id: run_id, section: section.to_s, error_class: error.class.name)
      Truffler.config.logger.warn("truffler: broadcast failed (#{error.class.name}) for run #{run_id}")
      Rails.error.report(error, handled: true, context: { run_id: run_id, section: section.to_s }) if rails_error_reporter?
    end

    def rails_error_reporter?
      defined?(Rails) && Rails.respond_to?(:error) && Rails.error.respond_to?(:report)
    end
  end
end
