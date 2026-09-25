require "erb"

module Truffler
  module Test
    # Loads the gem tables from the install generator's migration template, so
    # the shipped migration is what the tests run against.
    module Schema
      TEMPLATE = File.expand_path("../../lib/generators/truffler/install/templates/migration.rb.tt", __dir__)

      Context = Struct.new(:migration_version, :record_id_type, :vector_dimensions) do
        def render(source)
          ERB.new(source, trim_mode: "-").result(binding)
        end
      end

      def self.load
        context = Context.new("[#{ActiveRecord::Migration.current_version}]", "bigint", nil)
        namespace = Module.new
        namespace.module_eval(context.render(File.read(TEMPLATE)), TEMPLATE)
        namespace.const_get(:CreateTrufflerTables).migrate(:up)
        use_pgvector_column if Database.pgvector?
      end

      # The generator writes `t.vector` (from the neighbor gem) when the host
      # passes dimensions. The suite mixes vector widths, so it swaps in an
      # unconstrained pgvector column instead.
      def self.use_pgvector_column
        connection = ActiveRecord::Base.connection
        connection.execute("ALTER TABLE truffler_embeddings ALTER COLUMN embedding TYPE vector USING NULL")
        connection.schema_cache.clear!
        Records::Embedding.reset_column_information
      end

      # Hides a gem table for the block, like a host that upgraded the gem
      # without running its new migration.
      def self.without_table(name)
        connection = ActiveRecord::Base.connection
        connection.rename_table(name, "#{name}_hidden")
        yield
      ensure
        connection.rename_table("#{name}_hidden", name)
      end
    end
  end
end

Truffler::Test::Schema.load
