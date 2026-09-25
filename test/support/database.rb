ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

ActiveRecord::Encryption.configure(
  primary_key: "test" * 8,
  deterministic_key: "deterministic" * 3,
  key_derivation_salt: "salt" * 8
)

module Truffler
  module Test
    module Database
      def self.clean
        connection = ActiveRecord::Base.connection
        connection.tables.each do |table|
          connection.execute("DELETE FROM #{connection.quote_table_name(table)}") unless table.start_with?("ar_", "schema_")
        end
      end
    end
  end
end
