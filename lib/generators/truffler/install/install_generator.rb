require "rails/generators"
require "rails/generators/active_record"

module Truffler
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      RECORD_ID_TYPES = %w[bigint integer string uuid].freeze

      source_root File.expand_path("templates", __dir__)

      class_option :record_id_type, type: :string, default: "bigint",
        desc: "Column type for record ids (#{RECORD_ID_TYPES.join(', ')})"
      class_option :vector_dimensions, type: :numeric,
        desc: "Store embeddings in a pgvector column of this width (Postgres with neighbor)"

      def validate_options
        return if RECORD_ID_TYPES.include?(record_id_type)

        raise Thor::Error, "--record-id-type must be one of #{RECORD_ID_TYPES.join(', ')}"
      end

      def create_migration_file
        migration_template "migration.rb.tt", File.join(db_migrate_path, "create_truffler_tables.rb")
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/truffler.rb"
      end

      def create_channel
        template "channel.rb.tt", "app/channels/truffler_channel.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end

      def record_id_type
        options[:record_id_type]
      end

      def vector_dimensions
        options[:vector_dimensions]&.to_i
      end
    end
  end
end
