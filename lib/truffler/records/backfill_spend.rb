module Truffler
  module Records
    # The backfill spend ledger: one row per model, tenant (nil for the
    # app-wide ledger), and vocabulary version, so a spend cap holds across
    # runs, reruns, and overlapping BackfillJob chains. Spend is reserved and
    # settled in SQL, never read, added to, and written back.
    class BackfillSpend < ActiveRecord::Base
      self.table_name = "truffler_backfill_spends"
      TENANT_KEY_RECHECK = 1.minute

      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }

      # False on apps that upgraded the gem without running
      # `rails g truffler:upgrade`; warns once per process.
      def self.available?
        return true if connection.data_source_exists?(table_name)

        warn_missing
        false
      end

      def self.for_ledger(model, tenant_key)
        tenant_ledgers? ? for_model(model).where(tenant_key: tenant_key) : for_model(model)
      end

      # Before `rails g truffler:upgrade` adds tenant_key, every tenant
      # shares the app-wide row. Before 0.1.6 rows were keyed by the whole
      # vocabulary version; pass it as `legacy_version:` and the first lookup
      # takes that row over instead of starting from zero.
      def self.ledger(model, version, tenant_key: nil, legacy_version: nil)
        attributes = { record_type: model.polymorphic_name, vocabulary_version: version }
        attributes[:tenant_key] = tenant_key if tenant_ledgers?
        adopt(attributes, legacy_version) if legacy_version && legacy_version != version
        create_or_find_by!(attributes)
      end

      def self.adopt(attributes, legacy_version)
        return if exists?(attributes)

        where(attributes.merge(vocabulary_version: legacy_version)).update_all(vocabulary_version: attributes[:vocabulary_version])
      rescue ActiveRecord::RecordNotUnique
        nil
      end
      private_class_method :adopt

      # A worker booted before `db:migrate` added tenant_key has the old
      # columns cached, so a miss reloads them at most once per
      # TENANT_KEY_RECHECK and the worker moves to tenant ledgers without a
      # restart.
      def self.tenant_ledgers?
        return true if column_names.include?("tenant_key")

        if recheck_tenant_key?
          reset_column_information
          return true if column_names.include?("tenant_key")
        end
        warn_missing_tenant_key
        false
      end

      def self.recheck_tenant_key?
        now = Time.current
        return false if @tenant_key_checked_at && now - @tenant_key_checked_at < TENANT_KEY_RECHECK

        @tenant_key_checked_at = now
        true
      end
      private_class_method :recheck_tenant_key?

      def self.warn_missing_tenant_key
        return if @missing_tenant_warned

        @missing_tenant_warned = true
        Truffler.config.logger.warn("[truffler] #{table_name}.tenant_key is missing, so backfill spend caps are app-wide. " \
          "Run `bin/rails g truffler:upgrade && bin/rails db:migrate`.")
      end
      private_class_method :warn_missing_tenant_key

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
