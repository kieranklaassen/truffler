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
      def self.mark_supplied_failed(ids, error_class:)
        now = Time.current
        set = "attempts = attempts + 1, status = ?, priority = 'backfill', last_error_class = ?, claimed_at = NULL, updated_at = ?"
        scope = where(id: ids)
        scope.where("attempts + 1 >= ?", Truffler.config.max_attempts).update_all([ set, "failed", error_class, now ])
        scope.where.not(status: "failed").update_all([ set, "pending", error_class, now ])
      end

      def self.mark_labeled(ids, version:)
        now = Time.current
        where(id: ids, status: "labeling").update_all(status: "labeled", vocabulary_version: version, labeled_at: now, attempts: 0,
          last_error_class: nil, claimed_at: nil, updated_at: now)
      end
    end
  end
end
