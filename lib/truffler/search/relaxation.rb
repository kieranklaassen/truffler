module Truffler
  module Search
    # Zero-result relaxation (0.1.6). When a search under the encoding's
    # filters returns nothing, the filters are demoted to soft boosts
    # (Encoding#relax) and the words they consumed become keywords again.
    # It relaxes as little as it can: first only the filters no record in
    # the tenant carries at their threshold ("Source: email" in a tenant with
    # no email sources), keeping the rest hard; if that still finds nothing,
    # every filter, but only when the words given back (or an exact or vector
    # match) still narrow the search: relaxing into "every record in the
    # tenant" would show unrelated results, so that stays empty.
    #
    # Both attempts run as one UNION ALL query, so relaxation costs a single
    # extra SELECT and only on an empty result. Each "these filters are
    # missing" branch is gated on label presence in the tenant, so at most
    # one of them can return rows; the relax-everything branch ranks after
    # it. With more than MAX_PARTIAL_FILTERS filters only the
    # relax-everything branch runs, to bound the branch count (2^n - 1).
    class Relaxation
      MAX_PARTIAL_FILTERS = 3
      TIER = "truffler_relaxed_tier".freeze
      BRANCH = "truffler_relaxed_branch".freeze
      SCORE_COLUMNS = %i[truffler_score truffler_label_score truffler_text_score truffler_keyword_score truffler_exact_score].freeze

      Outcome = Data.define(:records, :encoding, :relaxed_labels)

      # `sql` builds the search's Sql for an encoding.
      def initialize(model, encoding, sql:)
        @model = model
        @encoding = encoding
        @sql = sql
      end

      # The relaxed search's outcome, or nil when there is no filter to relax
      # or the relaxed search is still empty.
      def call(scope, limit: nil)
        filters = @encoding&.filters.to_h
        return if filters.empty?

        branches = partial_branches(filters.keys)
        branches << filters.keys unless @sql.call(@encoding.relax(filters.keys)).every_base_record?
        return if branches.empty?

        rows = @model.find_by_sql(union_sql(scope, filters, branches, limit))
        return if rows.empty?

        partial, full = rows.partition { |row| Integer(row[TIER]) == 1 }
        records = partial.presence || full
        relaxed = branches.fetch(Integer(records.first[BRANCH]))
        Outcome.new(records: records, encoding: @encoding.relax(relaxed), relaxed_labels: relaxed)
      end

      private

      # Every nonempty proper subset of the filters, as a "missing" set.
      def partial_branches(keys)
        return [] if keys.size > MAX_PARTIAL_FILTERS

        (1...keys.size).flat_map { |size| keys.combination(size).to_a }
      end

      def union_sql(scope, filters, branches, limit)
        present = ->(key) { @sql.call(@encoding).label_present_sql(key, filters.fetch(key)) }
        selects = branches.each_with_index.map do |missing, index|
          full = missing.size == filters.size
          guard = (filters.keys - missing).map { |key| present.call(key) } + missing.map { |key| "NOT #{present.call(key)}" }
          branch_sql(scope, missing, index, tier: full ? 0 : 1, guard: full ? [] : guard, limit: limit)
        end
        sql = "SELECT * FROM (#{selects.join(' UNION ALL ')}) truffler_relaxed ORDER BY #{ordering.join(', ')}"
        limit ? "#{sql} LIMIT #{Integer(limit)}" : sql
      end

      def branch_sql(scope, missing, index, tier:, guard:, limit:)
        search = @sql.call(@encoding.relax(missing))
        alias_name = "truffler_relaxed_#{index}"
        scores = search.score_column_names
        columns = @model.column_names.map { |name| "#{alias_name}.#{quote_column(name)}" } +
          SCORE_COLUMNS.map { |name| scores.include?(name) ? "#{alias_name}.#{name}" : "0.0 AS #{name}" } +
          [ "#{tier} AS #{TIER}", "#{index} AS #{BRANCH}" ]
        where = guard.any? ? " WHERE #{guard.join(' AND ')}" : ""
        "SELECT #{columns.join(', ')} FROM (#{search.relation(scope, limit: limit).to_sql}) #{alias_name}#{where}"
      end

      def ordering
        order_column, direction = @model.truffler_definition.order
        [ "#{TIER} DESC", "truffler_score DESC", ("#{quote_column(order_column)} #{direction == :asc ? 'ASC' : 'DESC'}" if order_column),
          "#{quote_column(@model.primary_key)} DESC" ].compact
      end

      def quote_column(name)
        @model.connection.quote_column_name(name)
      end
    end
  end
end
