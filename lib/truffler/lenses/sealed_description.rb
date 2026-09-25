module Truffler
  module Lenses
    # Stores `description` through Lenses.seal, so encrypted models keep only
    # ciphertext (or nothing) in the lens tables (R44).
    module SealedDescription
      extend ActiveSupport::Concern

      included do
        before_save :seal_description
      end

      def description
        return @description_text if defined?(@description_text)

        Lenses.unseal(described_model, read_attribute(:description))
      end

      def description=(text)
        @description_text = text
      end

      private

      def seal_description
        write_attribute(:description, Lenses.seal(described_model, @description_text)) if defined?(@description_text)
      end
    end
  end
end
