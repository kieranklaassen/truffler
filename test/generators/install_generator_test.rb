require "test_helper"
require "rails/generators/test_case"
require "generators/truffler/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Truffler::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  TABLES = %w[truffler_embeddings truffler_labels truffler_query_misses truffler_record_states].freeze

  test "writes the migration, initializer, and channel" do
    run_generator

    assert_migration "db/migrate/create_truffler_tables.rb", /create_table :truffler_labels/
    assert_file "config/initializers/truffler.rb", /Truffler.configure/
    assert_file "app/channels/truffler_channel.rb" do |channel|
      assert_match(/stream_from "truffler:\#{user_key}"/, channel)
      assert_match(/def authorized_user_key/, channel)
    end
  end

  test "the generated migration creates the four tables with unique indexes on SQLite" do
    run_generator
    connection = migrate_generated

    assert_equal TABLES, (connection.tables & TABLES).sort
    assert unique_index?(connection, "truffler_labels", %w[record_type record_id label_key])
    assert unique_index?(connection, "truffler_record_states", %w[record_type record_id])
    assert unique_index?(connection, "truffler_embeddings", %w[record_type record_id])
    assert_equal :binary, connection.columns("truffler_embeddings").find { |column| column.name == "embedding" }.type
  end

  test "record ids can be strings for uuid primary keys" do
    run_generator [ "--record-id-type=string" ]
    connection = migrate_generated

    assert_equal :string, connection.columns("truffler_labels").find { |column| column.name == "record_id" }.type
  end

  test "rejects an unknown record id type" do
    assert_raises(Thor::Error) { run_generator [ "--record-id-type=json" ], debug: true }
  end

  test "a pgvector width writes a vector column" do
    run_generator [ "--vector-dimensions=256" ]

    assert_migration "db/migrate/create_truffler_tables.rb", /t\.vector :embedding, limit: 256/
  end

  private

  def migrate_generated
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    path = Dir[File.join(destination_root, "db/migrate/*_create_truffler_tables.rb")].sole
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    namespace.const_get(:CreateTrufflerTables).new.exec_migration(Scratch.connection, :up)
    Scratch.connection
  end

  def unique_index?(connection, table, columns)
    connection.indexes(table).any? { |index| index.unique && index.columns == columns }
  end
end
