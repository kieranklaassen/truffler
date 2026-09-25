module Truffler
  module Jobs
    # Embeds one record's declared fields and stores the vector. Arguments are
    # the record type and id only. On an embedder failure nothing is written,
    # `embedded_at` stays as it was, and the job retries; labels are untouched.
    # A record the definition no longer indexes is skipped.
    class EmbedJob < ActiveJob::Base
      queue_as { Truffler.config.queue_name }

      retry_on ClientError, IncompleteAnswers, wait: :polynomially_longer, attempts: 10 do
        nil
      end

      def perform(record_type, record_id)
        model = record_type.safe_constantize
        definition = model.try(:truffler_definition)
        return unless definition && Embeddings.managed?(definition)

        record = model.find_by(model.primary_key => record_id)
        return Records::Embedding.where(record_type: record_type, record_id: record_id).delete_all unless record
        return unless definition.indexable?(record)

        settings = definition.embeddings
        fingerprint = Embeddings.fingerprint(definition)
        text = Embeddings.text_for(definition, record)
        vector = Embeddings.embedder.embed([ text ], model: settings[:model], dimensions: settings[:dimensions]).vectors.first
        Embeddings::VectorStore.for(model).write(model, record, vector, fingerprint: fingerprint)

        now = Time.current
        Records::RecordState.where(record_type: record_type, record_id: record.id)
          .update_all(embedding_fingerprint: fingerprint, embedded_at: now, updated_at: now)
      end
    end
  end
end
