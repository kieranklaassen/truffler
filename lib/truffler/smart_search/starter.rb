module Truffler
  module SmartSearch
    # Fires the explicit action (R22, R23). It runs the same keystroke search
    # the host shows, snapshots candidate ids from the caller's scope (R17),
    # stores the run, supersedes the searcher's previous run (KTD11), and
    # enqueues `SmartSearchJob(run_id)`. The keystroke list is not touched.
    #
    # The snapshot is the keystroke ranking. When no encoding applied yet
    # and that ranking is short of `rerank_depth` (a model with no local
    # text search on a first-time intent query, AE10), the newest records in
    # scope join the pool so the awaited encoding's filters have something
    # to narrow; at most `smart_candidate_pool` ids are kept.
    class Starter
      def initialize(model, query, tenant:, scope:, user:, surface: nil, suppressed: [], store: Store.new, config: Truffler.config,
        dispatch: ->(run) { Jobs::SmartSearchJob.perform_later(run.id) })
        @model = model
        @query = Search::Query.wrap(query)
        @tenant = tenant
        @scope = scope
        @user = user
        @surface = surface
        @suppressed = Array(suppressed).map(&:to_s)
        @store = store
        @config = config
        @dispatch = dispatch
      end

      def call
        Current.scope do
          result = keystroke.call
          local_ids = result.ids
          run = Run.create(@model, query: @query.raw.strip, tenant_key: keystroke.tenant_key, user_key: keystroke.user_key,
            surface: keystroke.surface, suppressed: @suppressed, pool_ids: pool(result, local_ids), local_ids: local_ids,
            local_weak: result.local_weak?, explicit_action: result.explicit_action, store: @store)
          previous = @store.supersede(run.record_type, run.tenant_key, run.user_key, run.surface, run.id)
          Run.load(previous, store: @store).cancel! if previous
          Instrumentation.instrument(:smart_search, run_id: run.id, record_type: run.record_type, tenant_key: run.tenant_key,
            surface: run.surface, candidate_count: run.pool_ids.size, local_count: local_ids.size)
          @dispatch.call(run)
          run
        end
      end

      private

      def definition
        @model.truffler_definition
      end

      def keystroke
        @keystroke ||= Search::Keystroke.new(@model, @query, tenant: @tenant, scope: @scope, user: @user, suppressed: @suppressed,
          surface: @surface, limit: [ @config.rerank_depth, Search::Keystroke::DEFAULT_LIMIT ].max)
      end

      def pool(result, local_ids)
        depth = @config.rerank_depth
        pool = local_ids.first(depth)
        return pool if result.encoding_status == :cached || definition.labels.empty? || pool.size >= depth

        pool + newest_in_scope(exclude: pool, limit: [ @config.smart_candidate_pool - pool.size, 0 ].max, time: result.encoding&.time)
      end

      def newest_in_scope(exclude:, limit:, time:)
        return [] if limit.zero?

        sql = Search::Sql.new(@model, tenant_key: keystroke.tenant_key, query: @query, encoding: Search::Encoding.new(time: time))
        relation = sql.base(keystroke.scope).where.not(@model.primary_key => exclude)
        column, direction = definition.order
        relation = column ? relation.reorder(column => direction) : relation.unscope(:order)
        relation = relation.order(@model.primary_key => :desc)
        relation.limit(limit).pluck(@model.primary_key)
      end
    end
  end
end
