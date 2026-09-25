module Truffler
  module Search
    # Builds the one keystroke query of KTD8, scored per KTD20:
    #
    #   w_label * SUM(weight * value) over the intent's nonzero label keys
    #   + w_text * text similarity (a top-K join, inline SQL, or the store's top-K CASE)
    #   + w_keyword * keyword hit + w_exact * exact-source hit
    #   + SOFT_KEYWORD * w_keyword * soft keyword hit
    #
    # A weighted dot product, not cosine: cosine would divide out magnitude
    # and let a record high on unrelated labels outrank the one the query
    # asked for. Hard filters are EXISTS subqueries that run before scoring.
    #
    # At scale: when every record past the filters is a candidate (label-only
    # and filtered searches), label scores come from one grouped aggregate
    # LEFT JOINed on record_id instead of a subquery per row. A store with
    # `neighbors_sql` (NeighborStore on Postgres) is LEFT JOINed the same
    # way, so text similarity is read from the tenant's top-K. Relation
    # sources run once, as `id = ANY(ARRAY(subquery))` on Postgres.
    class Sql
      LABELS = "truffler_labels".freeze
      LABEL_SCORES = "truffler_label_scores".freeze
      NEIGHBORS = "truffler_neighbors".freeze
      # Share of the keyword weight a soft keyword hit adds (see Encoding).
      SOFT_KEYWORD = 0.25

      attr_reader :model, :tenant_key, :query, :encoding, :vector, :weights

      def initialize(model, tenant_key:, query:, encoding: nil, vector: nil, weights: nil, store: nil)
        @model = model
        @tenant_key = tenant_key&.to_s
        @query = query
        @encoding = encoding || Encoding.new
        @vector = vector
        @weights = weights || definition.ranking
        @store = store
      end

      # The caller's relation, ANDed with the tenant, the time range, and the hard filters.
      def base(scope)
        scope = scope.where(definition.tenant_column => tenant_key) if definition.scoped?
        scope = within_time(scope, encoding.time) if encoding.time
        encoding.filters.reduce(scope) { |relation, (key, threshold)| relation.where(Arel.sql(label_filter_sql(key, threshold))) }
      end

      # Every record the query can return, before ranking. Under a label
      # filter the filter decides membership and text matches only rank.
      def candidates(scope)
        base = base(scope)
        base = base.joins(Arel.sql(neighbors_join_sql)) if neighbors_sql
        return base if every_base_record?

        conditions = [ keyword_sql, exact_sql, (text_candidate_sql if text_score_sql) ].compact
        base.where(Arel.sql(conditions.any? ? conditions.map { |condition| "(#{condition})" }.join(" OR ") : "1 = 0"))
      end

      def relation(scope, limit: nil)
        relation = candidates(scope)
        relation = relation.joins(Arel.sql(label_scores_join_sql)) if grouped_label_scores?
        relation = relation.select(Arel.sql("#{table}.*")) if relation.select_values.empty?
        relation = relation.select(*score_columns.map { |name, sql| Arel.sql("(#{sql}) AS #{name}") })
        relation = relation.reorder(*ordering)
        limit ? relation.limit(limit) : relation
      end

      # The label term: a per-candidate subquery when sources narrow the
      # candidates, else the grouped join's score.
      def label_score_sql
        return if encoding.intent_vector.empty?
        return "COALESCE(#{connection.quote_table_name(LABEL_SCORES)}.score, 0.0)" if grouped_label_scores?

        "COALESCE((SELECT SUM(#{label_case_sql}) FROM #{quoted_labels} " \
          "WHERE #{label_scope_sql} AND #{label_keys_sql}), 0.0)"
      end

      def sources
        [ (:keyword if keyword_sql), (:exact if exact_sql), (:vector if text_score_sql),
          (:labels unless encoding.empty?) ].compact
      end

      def keywords
        @keywords ||= encoding.keywords(query, keep: -> { Filler.label_words(definition, tenant_key) })
      end

      # Whether any record in the tenant carries `key` at or above `threshold`.
      def label_present_sql(key, threshold)
        tenant = definition.scoped? ? " AND #{label_column('tenant_key')} = #{quote(tenant_key)}" : ""
        "EXISTS (SELECT 1 FROM #{quoted_labels} WHERE #{label_column('record_type')} = #{quote(model.polymorphic_name)}#{tenant} " \
          "AND #{label_column('label_key')} = #{quote(key)} AND #{label_column('value')} >= #{Float(threshold)})"
      end

      def score_column_names
        score_columns.keys
      end

      # Every record past the tenant, time, and filters is a candidate.
      def every_base_record?
        label_only? || encoding.filters.any?
      end

      private

      def definition
        model.truffler_definition
      end

      def connection
        model.connection
      end

      def quote(value)
        connection.quote(value)
      end

      def table
        connection.quote_table_name(model.table_name)
      end

      def column(name)
        "#{table}.#{connection.quote_column_name(name)}"
      end

      def primary_key
        column(model.primary_key)
      end

      def quoted_labels
        connection.quote_table_name(LABELS)
      end

      def label_column(name)
        "#{quoted_labels}.#{connection.quote_column_name(name)}"
      end

      def label_scope_sql
        tenant = definition.scoped? ? " AND #{label_column('tenant_key')} = #{quote(tenant_key)}" : ""
        "#{label_column('record_type')} = #{quote(model.polymorphic_name)}#{tenant} AND #{label_column('record_id')} = #{primary_key}"
      end

      def within_time(scope, range)
        arrived_at = model.arel_table[definition.arrived_at_column]
        scope = scope.where(arrived_at.gteq(range.from))
        range.to ? scope.where(arrived_at.lt(range.to)) : scope
      end

      def label_case_sql
        cases = encoding.intent_vector.map { |key, weight| "WHEN #{quote(key)} THEN #{Float(weight)} * #{label_column('value')}" }
        "CASE #{label_column('label_key')} #{cases.join(' ')} ELSE 0.0 END"
      end

      def label_keys_sql
        "#{label_column('label_key')} IN (#{encoding.intent_vector.keys.map { |key| quote(key) }.join(', ')})"
      end

      def grouped_label_scores?
        encoding.intent_vector.any? && every_base_record?
      end

      # One aggregate over the tenant's rows for the intent's keys, which
      # `index_truffler_labels_for_search` (with INCLUDE (record_id)) serves
      # as an index-only scan.
      def label_scores_join_sql
        tenant = definition.scoped? ? " AND #{label_column('tenant_key')} = #{quote(tenant_key)}" : ""
        scores = connection.quote_table_name(LABEL_SCORES)
        "LEFT JOIN (SELECT #{label_column('record_id')} AS record_id, SUM(#{label_case_sql}) AS score FROM #{quoted_labels} " \
          "WHERE #{label_column('record_type')} = #{quote(model.polymorphic_name)}#{tenant} AND #{label_keys_sql} " \
          "GROUP BY #{label_column('record_id')}) #{scores} ON #{scores}.record_id = #{primary_key}"
      end

      def neighbors_sql
        return @neighbors_sql if defined?(@neighbors_sql)

        @neighbors_sql = (store.neighbors_sql(model, tenant_key: tenant_key, vector: vector) if vector && store.respond_to?(:neighbors_sql))
      end

      def neighbors_join_sql
        neighbors = connection.quote_table_name(NEIGHBORS)
        "LEFT JOIN (#{neighbors_sql}) #{neighbors} ON #{neighbors}.record_id = #{primary_key}"
      end

      def label_filter_sql(key, threshold)
        "EXISTS (SELECT 1 FROM #{quoted_labels} WHERE #{label_scope_sql} AND #{label_column('label_key')} = #{quote(key)} " \
          "AND #{label_column('value')} >= #{Float(threshold)})"
      end

      # All label terms (or a blank query) means label-only matches: every
      # record past the hard filters is a candidate, ranked by the label
      # term. So is an applied encoding on a model with nothing local to
      # search its keywords with.
      def label_only?
        return true if keywords.empty?

        !encoding.empty? && definition.keyword.blank? && !text_score_sql && definition.exact_sources.empty?
      end

      def keyword_sql
        return @keyword_sql if defined?(@keyword_sql)

        @keyword_sql = keywords.empty? ? nil : keyword_condition(definition.keyword, keywords)
      end

      # Any soft keyword hit; soft keywords rank and never narrow.
      def soft_keyword_sql
        return @soft_keyword_sql if defined?(@soft_keyword_sql)

        conditions = (encoding.soft_keyword_tokens - keywords).uniq.filter_map { |token| keyword_condition(definition.keyword, [ token ]) }
        @soft_keyword_sql = conditions.empty? ? nil : conditions.map { |condition| "(#{condition})" }.join(" OR ")
      end

      def keyword_condition(source, tokens)
        case source
        when Array
          return if source.empty?

          tokens.map do |token|
            pattern = quote("%#{model.sanitize_sql_like(token)}%")
            "(#{source.map { |name| "LOWER(#{column(name)}) LIKE #{pattern} ESCAPE '\\'" }.join(' OR ')})"
          end.join(" AND ")
        when nil then nil
        else membership_sql(source.call(tenant_scope, tokens))
        end
      end

      def exact_sql
        return @exact_sql if defined?(@exact_sql)

        values = query.blank? ? [] : (query.exact_tokens + [ query.normalized ]).uniq
        conditions = definition.exact_sources.values.flat_map do |callable|
          values.filter_map { |value| membership_sql(callable.call(tenant_scope, value)) }
        end
        @exact_sql = conditions.empty? ? nil : conditions.join(" OR ")
      end

      def text_score_sql
        return @text_score_sql if defined?(@text_score_sql)

        @text_score_sql =
          if neighbors_sql then "COALESCE(#{connection.quote_table_name(NEIGHBORS)}.similarity, 0.0)"
          elsif vector && store then store.similarity_sql(model, tenant_key: tenant_key, vector: vector).to_s
          end
      end

      def text_candidate_sql
        "#{text_score_sql} > #{Float(weights[:min_similarity])}"
      end

      def store
        @store ||= Embeddings::VectorStore.for(model) if definition.embeddings
      end

      def tenant_scope
        definition.scoped? ? model.where(definition.tenant_column => tenant_key) : model.all
      end

      # An id list is the fast path. A relation runs once as an array on
      # Postgres, where `IN (subquery)` becomes a hashed filter over every
      # tenant row.
      def membership_sql(result)
        case result
        when ActiveRecord::Relation
          subquery = result.reselect(result.klass.arel_table[result.klass.primary_key]).to_sql
          connection.adapter_name.match?(/postg/i) ? "#{primary_key} = ANY(ARRAY(#{subquery}))" : "#{primary_key} IN (#{subquery})"
        when nil then nil
        else
          ids = Array(result)
          "#{primary_key} IN (#{ids.map { |id| quote(id) }.join(', ')})" if ids.any?
        end
      end

      def score_columns
        terms = {
          truffler_label_score: (label_score_sql && "#{Float(weights[:label])} * #{label_score_sql}"),
          truffler_text_score: (text_score_sql && "#{Float(weights[:text])} * #{text_score_sql}"),
          truffler_keyword_score: keyword_score_sql,
          truffler_exact_score: (exact_sql && "#{Float(weights[:exact])} * (CASE WHEN #{exact_sql} THEN 1.0 ELSE 0.0 END)")
        }.compact
        { truffler_score: terms.any? ? terms.values.map { |term| "(#{term})" }.join(" + ") : "0.0", **terms }
      end

      def keyword_score_sql
        weight = Float(weights[:keyword])
        terms = [ (keyword_sql && "#{weight} * (CASE WHEN #{keyword_sql} THEN 1.0 ELSE 0.0 END)"),
          (soft_keyword_sql && "#{weight * SOFT_KEYWORD} * (CASE WHEN #{soft_keyword_sql} THEN 1.0 ELSE 0.0 END)") ].compact
        terms.map { |term| "(#{term})" }.join(" + ") if terms.any?
      end

      def ordering
        order_column, direction = definition.order
        [ Arel.sql("truffler_score DESC"), (Arel.sql("#{column(order_column)} #{direction == :asc ? 'ASC' : 'DESC'}") if order_column),
          Arel.sql("#{primary_key} DESC") ].compact
      end
    end
  end
end
