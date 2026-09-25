require "test_helper"
require "rails/generators/test_case"
require "generators/truffler/upgrade/upgrade_generator"

class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Truffler::Generators::UpgradeGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    @previous_connection = Truffler::Generators::UpgradeGenerator.schema_connection
    Truffler::Generators::UpgradeGenerator.schema_connection = -> { Scratch.connection }
  end

  teardown do
    Truffler::Generators::UpgradeGenerator.schema_connection = @previous_connection
  end

  test "0.1.2: writes a migration that adds only the backfill spend ledger" do
    run_generator
    assert_migration "db/migrate/add_tenant_key_to_truffler_backfill_spends.rb"

    assert_migration "db/migrate/create_truffler_backfill_spends.rb" do |migration|
      assert_match(/create_table :truffler_backfill_spends/, migration)
      assert_no_match(/create_table :truffler_(labels|record_states|embeddings|query_misses|lenses)/, migration)
    end
    assert_no_file "config/initializers/truffler.rb"
  end

  test "0.1.2: the migration creates the ledger with a unique index and is a no-op when the table exists" do
    run_generator
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = Scratch.connection

    2.times { migration.new.exec_migration(connection, :up) }

    assert_equal [ "truffler_backfill_spends" ], connection.tables
    assert(connection.indexes("truffler_backfill_spends").any? { |index| index.unique && index.columns == %w[record_type vocabulary_version] })
    assert_equal %w[created_at id record_type requests spent_usd updated_at vocabulary_version],
      connection.columns("truffler_backfill_spends").map(&:name).sort
    migration.new.exec_migration(connection, :down)
    assert_empty connection.tables
  end

  test "0.1.5: adds tenant_key to an existing ledger, keeps its rows, and replaces the app-wide unique index" do
    run_generator
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = Scratch.connection
    migration.new.exec_migration(connection, :up)
    connection.execute("INSERT INTO truffler_backfill_spends (record_type, vocabulary_version, spent_usd, requests, created_at, updated_at) " \
      "VALUES ('Email', 'v1', 1.5, 3, '2026-01-01', '2026-01-01')")

    2.times { tenant_migration.new.exec_migration(connection, :up) }

    assert_includes connection.columns("truffler_backfill_spends").map(&:name), "tenant_key"
    indexes = connection.indexes("truffler_backfill_spends").index_by(&:name)
    assert_equal %w[index_truffler_backfill_spends_on_app_ledger index_truffler_backfill_spends_on_tenant_ledger], indexes.keys.sort
    assert_equal %w[record_type tenant_key vocabulary_version], indexes["index_truffler_backfill_spends_on_tenant_ledger"].columns
    assert_match(/tenant_key IS NULL/i, indexes["index_truffler_backfill_spends_on_app_ledger"].where)
    assert_equal [ [ "Email", nil, 1.5 ] ], connection.select_rows("SELECT record_type, tenant_key, spent_usd FROM truffler_backfill_spends")
    insert = "INSERT INTO truffler_backfill_spends (record_type, tenant_key, vocabulary_version, created_at, updated_at) " \
      "VALUES ('Email', %s, 'v1', '2026-01-01', '2026-01-01')"
    connection.execute(format(insert, "'1'"))
    connection.execute(format(insert, "'2'"))
    assert_raises(ActiveRecord::RecordNotUnique) { connection.execute(format(insert, "NULL")) }

    tenant_migration.new.exec_migration(connection, :down)
    assert_not_includes connection.columns("truffler_backfill_spends").map(&:name), "tenant_key"
  end

  test "0.1.5: the tenant_key migration is a no-op on a fresh install's ledger" do
    run_generator
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = Scratch.connection
    connection.create_table(:truffler_backfill_spends) do |t|
      t.string :record_type, null: false
      t.string :tenant_key
      t.string :vocabulary_version, null: false
    end
    connection.add_index :truffler_backfill_spends, %i[record_type tenant_key vocabulary_version], unique: true,
      name: "index_truffler_backfill_spends_on_tenant_ledger"
    connection.add_index :truffler_backfill_spends, %i[record_type vocabulary_version], unique: true, where: "tenant_key IS NULL",
      name: "index_truffler_backfill_spends_on_app_ledger"

    assert_nothing_raised { tenant_migration.new.exec_migration(connection, :up) }
    assert_equal 2, connection.indexes("truffler_backfill_spends").size
  end

  test "0.1.5: rerunning is idempotent: no new files and no conflict, before and after migrating" do
    first = run_generator
    files = migration_files
    second = run_generator

    assert_equal 2, files.size
    assert_equal files, migration_files
    assert_no_match(/conflict|already named/i, first + second)
    assert_match(/skip.*create_truffler_backfill_spends/, second)

    migration.new.exec_migration(Scratch.connection, :up)
    tenant_migration.new.exec_migration(Scratch.connection, :up)
    third = run_generator
    FileUtils.rm(files)
    fourth = run_generator

    assert_empty migration_files, "a migrated schema needs no new migration even when the files are gone"
    assert_no_match(/conflict|already named/i, third + fourth)
    assert_match(/skip.*add_tenant_key_to_truffler_backfill_spends/, fourth)
  end

  test "0.1.5: an app on the 0.1.2 ledger gets only the tenant_key migration" do
    Scratch.connection.create_table(:truffler_backfill_spends) do |t|
      t.string :record_type, null: false
      t.string :vocabulary_version, null: false
    end

    output = run_generator

    assert_equal [ "add_tenant_key_to_truffler_backfill_spends" ], migration_files.map { |path| File.basename(path, ".rb").sub(/\A\d+_/, "") }
    assert_no_match(/conflict/i, output)
  end

  test "0.1.5: without a database connection it still writes the missing migrations" do
    Truffler::Generators::UpgradeGenerator.schema_connection = -> { raise ActiveRecord::ConnectionNotEstablished }

    run_generator

    assert_equal 3, migration_files.size
  end

  private

  def migration_files
    Dir[File.join(destination_root, "db/migrate/*.rb")].sort
  end

  def migration
    load_migration("create_truffler_backfill_spends", :CreateTrufflerBackfillSpends)
  end

  def tenant_migration
    load_migration("add_tenant_key_to_truffler_backfill_spends", :AddTenantKeyToTrufflerBackfillSpends)
  end

  def load_migration(name, constant)
    path = Dir[File.join(destination_root, "db/migrate/*_#{name}.rb")].sole
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace.const_get(constant)
  end

  test "0.1.5: the covering labels index step is skipped on SQLite" do
    run_generator
    assert_no_migration "db/migrate/cover_truffler_labels_for_search.rb"
  end

  test "0.1.5: on Postgres without the covering index, the step writes a migration that adds it once" do
    skip "needs TRUFFLER_DATABASE_URL on Postgres" unless ActiveRecord::Base.connection.adapter_name.match?(/postg/i)

    connection = ActiveRecord::Base.connection
    connection.remove_index :truffler_labels, name: "index_truffler_labels_for_search", if_exists: true
    connection.add_index :truffler_labels, [ :record_type, :tenant_key, :label_key, :value ], name: "index_truffler_labels_for_search"
    Truffler::Generators::UpgradeGenerator.schema_connection = -> { connection }

    run_generator
    assert_migration "db/migrate/cover_truffler_labels_for_search.rb"
    load Dir[File.join(destination_root, "db/migrate/*cover_truffler_labels_for_search.rb")].first
    2.times { CoverTrufflerLabelsForSearch.new.exec_migration(connection, :up) }

    assert connection.index_name_exists?(:truffler_labels, "index_truffler_labels_for_search_covering")
    assert_not connection.index_name_exists?(:truffler_labels, "index_truffler_labels_for_search")
  ensure
    if connection&.adapter_name&.match?(/postg/i)
      connection.remove_index :truffler_labels, name: "index_truffler_labels_for_search_covering", if_exists: true
      connection.add_index :truffler_labels, [ :record_type, :tenant_key, :label_key, :value ], include: [ :record_id ],
        name: "index_truffler_labels_for_search", if_not_exists: true
    end
  end
end
