module Truffler
  module Records
    # The durable labeling queue: one row per record, carrying its status,
    # priority, attempts, and the vocabulary version it was labeled with.
    class RecordState < ActiveRecord::Base
      self.table_name = "truffler_record_states"

      STATUSES = %w[pending labeling labeled failed].freeze
      PRIORITIES = %w[live backfill].freeze

      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }

      # Only rows still claimed: a record edited mid-flight was reset to
      # pending and must be labeled again.
      def self.mark_labeled(ids, version:)
        now = Time.current
        where(id: ids, status: "labeling").update_all(status: "labeled", vocabulary_version: version, labeled_at: now, attempts: 0,
          last_error_class: nil, claimed_at: nil, updated_at: now)
      end
    end
  end
end
