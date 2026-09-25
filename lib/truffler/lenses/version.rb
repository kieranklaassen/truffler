module Truffler
  module Lenses
    # One drafted question set of a lens (R45). Versions are append-only:
    # regenerating adds a draft, activating retires the previous active one,
    # and restoring copies an earlier version forward as a new number.
    class Version < ActiveRecord::Base
      include SealedDescription

      self.table_name = "truffler_lens_versions"

      STATUSES = %w[draft active retired].freeze

      belongs_to :lens, class_name: "Truffler::Lenses::Lens", inverse_of: :versions
      serialize :questions, coder: JSON
      serialize :reused_keys, coder: JSON

      validates :status, inclusion: { in: STATUSES }

      def draft? = status == "draft"
      def active? = status == "active"

      def to_draft
        Draft.new(model: lens.model, scope: lens.scope, description: description, name: lens.name,
          questions: questions.to_h, reused: Array(reused_keys), lens: lens)
      end

      private

      def described_model
        lens.model
      end
    end
  end
end
