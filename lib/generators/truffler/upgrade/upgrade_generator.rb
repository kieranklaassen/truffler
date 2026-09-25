require "rails/generators"
require "rails/generators/active_record"

module Truffler
  module Generators
    # Adds the tables a newer Truffler needs to an app installed with an older
    # one. Each migration skips a table, column, or index that already exists.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_backfill_spends_migration
        migration_template "backfill_spends_migration.rb.tt", File.join(db_migrate_path, "create_truffler_backfill_spends.rb")
      end

      def create_backfill_spends_tenant_key_migration
        migration_template "backfill_spends_tenant_key_migration.rb.tt",
          File.join(db_migrate_path, "add_tenant_key_to_truffler_backfill_spends.rb")
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
