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
      end
    end
  end
end

Truffler::Test::Schema.load
