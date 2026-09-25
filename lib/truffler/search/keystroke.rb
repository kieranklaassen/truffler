module Truffler
  module Search
    # A tenant-scoped keystroke search (KTD8). It reads the query encoding
    # and query vector from the cache only, so no network call sits on the
    # keystroke (R12); a miss hands the query to the prefetch hook and the
    # results stand without it. Everything else is one SQL query.
    class Keystroke
      DEFAULT_LIMIT = 50

      attr_reader :model, :query, :tenant_key, :scope, :user_key, :suppressed, :surface, :limit

      def initialize(model, query, tenant:, scope:, user: nil, suppressed: [], surface: nil, limit: DEFAULT_LIMIT, weights: {},
        cache: EncodingCache.new)
        @model = model
        @definition = model.try(:truffler_definition) || raise(DefinitionError, "#{model.name} has no truffler declaration")
        @query = query.is_a?(Query) ? query : Query.new(query)
        @tenant_key = tenant&.to_s
        @scope = scope.nil? && !@definition.scoped? ? model.all : scope
        @user_key = self.class.user_key(user)
        @suppressed = Array(suppressed).map(&:to_s)
        @surface = surface&.to_s
        @limit = limit
        @weights = @definition.ranking.merge(weights.to_h { |key, weight| [ key.to_sym, Float(weight) ] })
        @cache = cache
        check_scope!
      end

      def self.user_key(user)
        case user
        when nil then nil
        when ActiveRecord::Base then "#{user.class.polymorphic_name}:#{user.id}"
        else user.to_s
        end
      end

      def call
        started = Instrumentation.monotonic_ms
        watermark = Time.current
        explicit_action = surface_action
        cached = read_encoding
        status = encoding_status(cached)
        encoding = cached&.without(suppressed)
        sql = sql(encoding)
        records = sql.relation(scope, limit: limit).to_a
        result = Result.new(records: records, query: query, encoding: encoding, encoding_status: status, watermark: watermark,
          explicit_action: explicit_action, sources: sql.sources, invite_row: invite_row(records, cached),
          weights: @weights, recount: ->(since) { count(since: since) })
        instrument(result, started)
        result
      end

      # How many records the same search would return that arrived after
      # `since` (R25). Reads the cache only and never prefetches.
      def count(since:)
        sql(read_encoding&.without(suppressed)).candidates(scope)
          .where(model.arel_table[@definition.arrived_at_column].gt(since)).count
      end

      private

      def check_scope!
        if @definition.scoped? && tenant_key.nil?
          raise MissingScope, "#{model.name}.truffler needs tenant: (declared tenant #{@definition.tenant_column})"
        end
        return if scope.is_a?(ActiveRecord::Relation) && scope.klass <= model

        raise MissingScope, "#{model.name}.truffler needs scope: to be a relation of #{model.name}"
      end

      def surface_action
        return unless surface

        @definition.surfaces.fetch(surface) { raise DefinitionError, "#{model.name} declares no surface #{surface}" }[:explicit_action]
      end

      def read_encoding
        return if query.blank? || @definition.labels.empty?

        @cache.read(model, query, tenant_key: tenant_key)
      end

      def read_vector
        return if query.blank? || !@definition.embeddings

        @vector ||= @cache.read_vector(model, query, tenant_key: tenant_key)
      end

      # Prefetches on a missing encoding or query vector; the status reports
      # the encoding only.
      def encoding_status(cached)
        return :none if query.blank?

        in_flight = prefetch?(cached) && @cache.prefetch(model, query, tenant_key: tenant_key, user_key: user_key)
        return :cached if cached
        return :none if @definition.labels.empty?

        in_flight ? :pending : :none
      end

      def prefetch?(cached)
        (cached.nil? && @definition.labels.any?) || (@definition.embeddings.present? && read_vector.nil?)
      end

      def sql(encoding)
        Sql.new(model, tenant_key: tenant_key, query: query, encoding: encoding, vector: read_vector, weights: @weights)
      end

      # R21: the Smart search row. A model with no local text search whose
      # encoding is not cached yet invites the action even when a blind index
      # matched, because intent queries resolve on the action there (AE10).
      def invite_row(records, cached)
        return if query.blank?

        reason =
          if @definition.keyword.blank? && cached.nil? then :encoding_pending
          elsif records.empty? then :empty
          elsif records.size < @definition.weak_below then :weak
          end
        { query: query.raw.strip, reason: reason } if reason
      end

      def instrument(result, started)
        payload = { record_type: model.polymorphic_name, tenant_key: tenant_key, surface: surface, outcome: result.encoding_status,
          result_count: result.records.size, filter_count: result.encoding&.filters&.size.to_i,
          boost_count: result.encoding&.intent_vector&.size.to_i, sources: result.sources.map(&:to_s),
          reason: result.invite_row&.dig(:reason), latency_ms: (Instrumentation.monotonic_ms - started).round(2) }
        payload[:query_digest] = Misses.digest(:query, query.normalized) if Misses.encrypted_model?(model)
        Instrumentation.instrument("search", payload)
      end
    end
  end
end
