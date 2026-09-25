require "rails/generators"
require "rails/generators/active_record"

module Truffler
  module Generators
    # Adds the tables and columns a newer Truffler needs to an app installed
    # with an older one. Safe to rerun: a step is skipped when db/migrate
    # already holds a migration of that name or the database already has
    # what it adds, so only missing migrations are written. Each migration
    # also skips a table, column, or index that already exists.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_attribute :schema_connection, default: -> { ActiveRecord::Base.connection }

      def create_backfill_spends_migration
        add_migration "backfill_spends_migration.rb.tt", "create_truffler_backfill_spends" do |connection|
          connection.table_exists?(:truffler_backfill_spends)
        end
      end

      def create_backfill_spends_tenant_key_migration
        add_migration "backfill_spends_tenant_key_migration.rb.tt", "add_tenant_key_to_truffler_backfill_spends" do |connection|
          connection.column_exists?(:truffler_backfill_spends, :tenant_key)
        end
      end

      private

      def add_migration(template, name, &applied)
        existing = self.class.migration_exists?(File.join(destination_root, db_migrate_path), name)
        if existing
          say_status :skip, "#{name} (#{File.basename(existing)} exists)", :yellow
        elsif schema_applied?(&applied)
          say_status :skip, "#{name} (already in the database)", :yellow
        else
          migration_template template, File.join(db_migrate_path, "#{name}.rb")
        end
      end

      # Without a database (not configured, not created yet) every step counts
      # as missing; the migrations themselves are no-ops where already applied.
      def schema_applied?
        yield schema_connection.call
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
