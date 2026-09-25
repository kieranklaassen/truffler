module Truffler
  module Records
    # The backfill spend ledger: one row per model and app-wide vocabulary
    # version, so a spend cap holds across runs, reruns, and overlapping
    # BackfillJob chains. Spend is reserved and settled in SQL, never read,
    # added to, and written back.
    class BackfillSpend < ActiveRecord::Base
      self.table_name = "truffler_backfill_spends"

      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }

      # False on apps that upgraded the gem without running
      # `rails g truffler:upgrade`; warns once per process.
      def self.available?
        return true if connection.data_source_exists?(table_name)

        warn_missing
        false
      end

      def self.ledger(model, version)
        create_or_find_by!(record_type: model.polymorphic_name, vocabulary_version: version)
      end

      def self.warn_missing
        return if @missing_warned

        @missing_warned = true
        Truffler.config.logger.warn("[truffler] #{table_name} is missing, so backfill spend caps apply per run only. " \
          "Run `bin/rails g truffler:upgrade && bin/rails db:migrate`.")
      end
      private_class_method :warn_missing

      # Adds `amount` unless that would pass `cap`; true when reserved.
      def reserve(amount, cap)
        scope = self.class.where(id: id)
        scope = scope.where("spent_usd + ? <= ?", amount, cap) if cap
        scope.update_all([ "spent_usd = spent_usd + ?, updated_at = ?", amount, Time.current ]) == 1
      end

      def settle(amount, requests: 1)
        self.class.where(id: id)
          .update_all([ "spent_usd = spent_usd + ?, requests = requests + ?, updated_at = ?", amount, requests, Time.current ])
      end

      def total
        self.class.where(id: id).pick(:spent_usd).to_f
      end
    end
  end
end
