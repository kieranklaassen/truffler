module Truffler
  module Embeddings
    # Finds records whose embedding is missing or was made under another
    # fingerprint (model, width, or fields changed) and enqueues EmbedJob for
    # them, newest first. The labeling backfill calls this alongside
    # relabeling.
    class Backfill
      attr_reader :model

      def initialize(model)
        @model = model
      end

      def stale_ids(limit: nil)
        definition = model.truffler_definition
        return [] unless Embeddings.managed?(definition)

        current = Records::RecordState.for_model(model).where(embedding_fingerprint: Embeddings.fingerprint(definition))
          .where.not(embedded_at: nil).select(:record_id)
        model.where.not(model.primary_key => current).order(model.primary_key => :desc).limit(limit).pluck(model.primary_key)
      end

      def enqueue(limit: nil)
        ids = stale_ids(limit: limit)
        ActiveJob.perform_all_later(ids.map { |id| Jobs::EmbedJob.new(model.polymorphic_name, id) }) if ids.any?
        ids.size
      end
    end
  end
end
