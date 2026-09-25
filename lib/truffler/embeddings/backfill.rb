module Truffler
  module Embeddings
    # Finds records whose embedding is missing or was made under another
    # fingerprint (model, width, or fields changed) and enqueues EmbedJob for
    # them, newest first, `batch_size` jobs at a time behind an id cursor.
    # ResumeJob runs a bounded pass on every sweep; hosts call `enqueue` with
    # no limit after enabling embeddings or changing the model, width, or
    # fields.
    class Backfill
      BATCH_SIZE = 1_000

      attr_reader :model

      def initialize(model)
        @model = model
      end

      def stale_ids(limit: nil, before: nil)
        definition = model.truffler_definition
        return [] unless Embeddings.managed?(definition)

        current = Records::RecordState.for_model(model).where(embedding_fingerprint: Embeddings.fingerprint(definition))
          .where.not(embedded_at: nil).select(:record_id)
        scope = model.where.not(model.primary_key => current)
        scope = scope.where(model.primary_key => ...before) if before
        scope.order(model.primary_key => :desc).limit(limit).pluck(model.primary_key)
      end

      def enqueue(limit: nil, batch_size: BATCH_SIZE)
        count = 0
        cursor = nil
        loop do
          take = limit ? [ batch_size, limit - count ].min : batch_size
          break unless take.positive?

          ids = stale_ids(limit: take, before: cursor)
          break if ids.empty?

          ActiveJob.perform_all_later(ids.map { |id| Jobs::EmbedJob.new(model.polymorphic_name, id) })
          count += ids.size
          cursor = ids.last
          break if ids.size < take
        end
        count
      end
    end
  end
end
