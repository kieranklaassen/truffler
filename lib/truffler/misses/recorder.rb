module Truffler
  module Misses
    # Stores one miss per call. Recording is best-effort: a failure is
    # instrumented by error class and never raises into the encoding path.
    class Recorder
      def call(model, tenant_key:, user_key:, query:)
        return unless model.try(:truffler_definition)

        normalized = Misses.normalize(query)
        return if normalized.empty?

        miss = Records::QueryMiss.create!(
          record_type: model.polymorphic_name,
          tenant_key: tenant_key&.to_s,
          query_digest: Misses.digest(:query, normalized),
          user_digest: (Misses.digest(:user, user_key) if user_key.present?),
          query_text: Misses.seal(model, normalized)
        )
        Instrumentation.instrument("miss", record_type: miss.record_type, tenant_key: miss.tenant_key, outcome: "recorded")
        miss
      rescue Truffler::Error, ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => error
        Instrumentation.instrument("miss", record_type: model.try(:name), outcome: "error", error_class: error.class.name)
        Truffler.config.logger.warn("[truffler] query miss not recorded: #{error.class.name}")
        nil
      end
      alias_method :record, :call
    end
  end
end
