module Truffler
  module Embeddings
    # Finds records whose embedding is missing or was made under another
    # fingerprint (model, width, or fields changed) and enqueues EmbedJob for
    # them, newest first, `batch_size` jobs at a time behind an id cursor.
    # It pages over the definition's index_scope, one tenant at a time when
    # given `tenant_key:`, skipping disabled tenants, with a NOT EXISTS
    # anti-join against truffler_record_states so each page stops at its
    # limit instead of materializing every current id. ResumeJob runs a
    # bounded pass on every sweep; hosts call `enqueue` with no limit after
    # enabling embeddings or changing the model, width, or fields.
    class Backfill
      BATCH_SIZE = 1_000
      STATES = Records::RecordState.table_name

      attr_reader :model

      def initialize(model)
        @model = model
      end

      def stale_ids(limit: nil, before: nil, tenant_key: nil)
        definition = model.truffler_definition
        return [] unless Embeddings.managed?(definition)
        return [] if tenant_key && !definition.tenant_enabled?(tenant_key)

        pk = model.arel_table[model.primary_key]
        scope = definition.index_relation(model.all).where(current_embedding_missing_sql(definition))
        if tenant_key && definition.scoped?
          scope = scope.where(definition.tenant_column => tenant_key)
        elsif definition.scoped? && Truffler.config.tenant_enabled
          scope = scope.where(definition.tenant_column => tenant_keys)
        end
        scope = scope.where(pk.lt(before)) if before
        scope.reorder(pk.desc).limit(limit).pluck(pk)
      end

      def enqueue(limit: nil, batch_size: BATCH_SIZE, tenant_key: nil)
        count = 0
        cursor = nil
        loop do
          take = limit ? [ batch_size, limit - count ].min : batch_size
          break unless take.positive?

          ids = stale_ids(limit: take, before: cursor, tenant_key: tenant_key)
          break if ids.empty?

          ActiveJob.perform_all_later(ids.map { |id| Jobs::EmbedJob.new(model.polymorphic_name, id) })
          count += ids.size
          cursor = ids.last
          break if ids.size < take
        end
        count
      end

      # The enabled tenants with records in the index scope, for per-tenant sweeps.
      def tenant_keys
        definition = model.truffler_definition
        return [ nil ] unless definition.scoped?

        definition.index_relation(model.all).reorder(nil).distinct.pluck(definition.tenant_column)
          .map(&:to_s).select { |key| definition.tenant_enabled?(key) }.sort
      end

      private

      def current_embedding_missing_sql(definition)
        pk = "#{model.quoted_table_name}.#{model.connection.quote_column_name(model.primary_key)}"
        ActiveRecord::Base.sanitize_sql_array([
          "NOT EXISTS (SELECT 1 FROM #{STATES} WHERE #{STATES}.record_type = ? AND #{STATES}.record_id = #{pk} " \
          "AND #{STATES}.embedding_fingerprint = ? AND #{STATES}.embedded_at IS NOT NULL)",
          model.polymorphic_name, Embeddings.fingerprint(definition)
        ])
      end
    end
  end
end
