ActiveRecord::Migration.verbose = false

ActiveRecord::Encryption.configure(
  primary_key: "test" * 8,
  deterministic_key: "deterministic" * 3,
  key_derivation_salt: "salt" * 8
)

module Truffler
  module Test
    # In-memory SQLite by default. With TRUFFLER_DATABASE_URL set (a
    # Postgres URL), the suite runs there instead: every run drops the
    # tables it finds and reloads the schema, and pgvector is enabled when
    # the server has it.
    module Database
      URL = ENV["TRUFFLER_DATABASE_URL"].presence

      def self.connect
        if URL
          ActiveRecord::Base.establish_connection(URL)
          reset_postgres
        else
          ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        end
      end

      def self.postgres?
        ActiveRecord::Base.connection.adapter_name.match?(/postg/i)
      end

      def self.sqlite?
        ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)
      end

      def self.pgvector?
        return @pgvector if defined?(@pgvector)

        @pgvector = postgres? && ActiveRecord::Base.connection.extension_enabled?("vector")
      end

      def self.reset_postgres
        connection = ActiveRecord::Base.connection
        connection.tables.each { |table| connection.drop_table(table, force: :cascade) }
        begin
          connection.enable_extension("vector")
        rescue ActiveRecord::StatementInvalid
          nil
        end
      end

      def self.clean
        connection = ActiveRecord::Base.connection
        connection.tables.each do |table|
          connection.execute("DELETE FROM #{connection.quote_table_name(table)}") unless table.start_with?("ar_", "schema_")
        end
      end
    end
  end
end

Truffler::Test::Database.connect
