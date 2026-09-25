module Truffler
  module Search
    # Builds the one keystroke query of KTD8, scored per KTD20:
    #
    #   w_label * SUM(weight * value) over the intent's nonzero label keys
    #   + w_text * text similarity (inline SQL, or the store's top-K CASE)
    #   + w_keyword * keyword hit + w_exact * exact-source hit
    #
    # A weighted dot product, not cosine: cosine would divide out magnitude
    # and let a record high on unrelated labels outrank the one the query
    # asked for. Hard filters are EXISTS subqueries that run before scoring.
    class Sql
      LABELS = "truffler_labels".freeze

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
        return base if label_only? || encoding.filters.any?

        conditions = [ keyword_sql, exact_sql, (text_candidate_sql if text_score_sql) ].compact
        base.where(Arel.sql(conditions.any? ? conditions.map { |condition| "(#{condition})" }.join(" OR ") : "1 = 0"))
      end

      def relation(scope, limit: nil)
        relation = candidates(scope)
        relation = relation.select(Arel.sql("#{table}.*")) if relation.select_values.empty?
        relation = relation.select(*score_columns.map { |name, sql| Arel.sql("(#{sql}) AS #{name}") })
        relation = relation.reorder(*ordering)
        limit ? relation.limit(limit) : relation
      end

      def label_score_sql
        intent = encoding.intent_vector
        return if intent.empty?

        cases = intent.map { |key, weight| "WHEN #{quote(key)} THEN #{Float(weight)} * #{label_column('value')}" }.join(" ")
        "COALESCE((SELECT SUM(CASE #{label_column('label_key')} #{cases} ELSE 0.0 END) FROM #{quoted_labels} " \
          "WHERE #{label_scope_sql} AND #{label_column('label_key')} IN (#{intent.keys.map { |key| quote(key) }.join(', ')})), 0.0)"
      end

      def sources
        [ (:keyword if keyword_sql), (:exact if exact_sql), (:vector if text_score_sql),
          (:labels unless encoding.empty?) ].compact
      end

      def keywords
        encoding.keywords(query)
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

        @keyword_sql = keywords.empty? ? nil : keyword_condition(definition.keyword)
      end

      def keyword_condition(source)
        case source
        when Array
          return if source.empty?

          keywords.map do |token|
            pattern = quote("%#{model.sanitize_sql_like(token)}%")
            "(#{source.map { |name| "LOWER(#{column(name)}) LIKE #{pattern} ESCAPE '\\'" }.join(' OR ')})"
          end.join(" AND ")
        when nil then nil
        else membership_sql(source.call(tenant_scope, keywords))
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

        @text_score_sql = (store.similarity_sql(model, tenant_key: tenant_key, vector: vector).to_s if vector && store)
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

      def membership_sql(result)
        case result
        when ActiveRecord::Relation then "#{primary_key} IN (#{result.reselect(result.klass.arel_table[result.klass.primary_key]).to_sql})"
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
          truffler_keyword_score: (keyword_sql && "#{Float(weights[:keyword])} * (CASE WHEN #{keyword_sql} THEN 1.0 ELSE 0.0 END)"),
          truffler_exact_score: (exact_sql && "#{Float(weights[:exact])} * (CASE WHEN #{exact_sql} THEN 1.0 ELSE 0.0 END)")
        }.compact
        { truffler_score: terms.any? ? terms.values.map { |term| "(#{term})" }.join(" + ") : "0.0", **terms }
      end

      def ordering
        order_column, direction = definition.order
        [ Arel.sql("truffler_score DESC"), (Arel.sql("#{column(order_column)} #{direction == :asc ? 'ASC' : 'DESC'}") if order_column),
          Arel.sql("#{primary_key} DESC") ].compact
      end
    end
  end
end
