require "erb"

module Truffler
  module Benchmark
    # A throwaway in-memory SQLite database holding the gem tables from the
    # install migration template, for running the benchmark outside an app.
    module Database
      TEMPLATE = File.expand_path("../../generators/truffler/install/templates/migration.rb.tt", __dir__)

      Context = Struct.new(:migration_version, :record_id_type, :vector_dimensions) do
        def render(source)
          ERB.new(source, trim_mode: "-").result(binding)
        end
      end

      module_function

      def connect!(database: ":memory:")
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database)
        load_schema
      end

      def load_schema
        context = Context.new("[#{ActiveRecord::Migration.current_version}]", "bigint", nil)
        namespace = Module.new
        namespace.module_eval(context.render(File.read(TEMPLATE)), TEMPLATE)
        ActiveRecord::Migration.suppress_messages { namespace.const_get(:CreateTrufflerTables).migrate(:up) }
      end
    end
  end
end
