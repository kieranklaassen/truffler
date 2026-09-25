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

  test "0.1.2: writes a migration that adds only the backfill spend ledger" do
    run_generator

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

  private

  def migration
    path = Dir[File.join(destination_root, "db/migrate/*_create_truffler_backfill_spends.rb")].sole
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace.const_get(:CreateTrufflerBackfillSpends)
  end
end
