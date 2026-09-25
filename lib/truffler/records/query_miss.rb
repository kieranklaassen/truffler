module Truffler
  module Records
    # A query whose encoding matched no label. Digests are keyed HMACs;
    # `query_text` is normalized plaintext on plaintext models, AR-encryption
    # ciphertext on encrypted models when it is configured, and null otherwise.
    class QueryMiss < ActiveRecord::Base
      self.table_name = "truffler_query_misses"

      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }
      scope :retained, ->(now = Time.current) { where(created_at: (now - Truffler.config.miss_retention)..) }
      scope :expired, ->(now = Time.current) { where(created_at: ...(now - Truffler.config.miss_retention)) }

      # The normalized query, decrypted on encrypted models; nil when no text
      # was stored or it can no longer be decrypted.
      def query
        return if query_text.nil?
        return query_text unless Misses.encrypted_model?(record_type.safe_constantize)

        ActiveRecord::Encryption.encryptor.decrypt(query_text)
      rescue ActiveRecord::Encryption::Errors::Base
        nil
      end
    end
  end
end
