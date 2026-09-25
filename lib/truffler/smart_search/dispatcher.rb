module Truffler
  module SmartSearch
    # The work of `SmartSearchJob`. It hands the run to the provider backup
    # when one is loaded (U11), then checks the per-user rerank cap without
    # taking a request slot, since each chunk takes its own; a denial here or
    # at a chunk pauses the run and pings (R26, AE5). Otherwise it waits
    # for an in-flight query encoding up to `encoding_deadline` (KTD10),
    # re-applies that encoding's filters to the snapshot, plans chunks of
    # `rerank_chunk_size`, and enqueues one `RerankChunkJob` per chunk.
    class Dispatcher
      def initialize(budget: Budget.new, encoder: QueryEncoding::Encoder.new, encodings: QueryEncoding::Cache.new,
        config: Truffler.config, deadline: config.encoding_deadline,
        enqueue: ->(run, index) { Jobs::RerankChunkJob.perform_later(run.id, index) }, providers: nil)
        @budget = budget
        @encoder = encoder
        @encodings = encodings
        @config = config
        @deadline = deadline
        @enqueue = enqueue
        @providers = providers
      end

      def call(run)
        return unless run.status == :pending && run.model.try(:truffler_definition)

        start_provider(run)
        decision = @budget.admit(priority: :rerank, user_key: run.user_key)
        if decision.denied?
          run.pause!(decision.reason)
          return
        end

        encoding = await_encoding(run)
        candidate_ids = filter(run, encoding)
        return if run.cancelled?

        run.plan!(candidate_ids: candidate_ids, chunk_size: @config.rerank_chunk_size, filters: encoding&.filters&.keys.to_a)
        run.chunk_count.times { |index| @enqueue.call(run, index) }
        run.ping(SMART) if candidate_ids.empty?
        candidate_ids
      end

      private

      def start_provider(run)
        providers = @providers || (Truffler::Providers if defined?(Truffler::Providers))
        return unless providers.respond_to?(:start)

        providers.start(run, query: run.query, tenant_key: run.tenant_key, user_key: run.user_key)
      rescue StandardError => error
        Instrumentation.instrument(:provider_start_failed, run_id: run.id, record_type: run.record_type, error_class: error.class.name)
        run.update_section(PROVIDER, status: :unavailable, error_class: error.class.name)
      end

      def await_encoding(run)
        model = run.model
        return if model.truffler_definition.vocabulary.labels_for(tenant_key: run.tenant_key, user_key: run.user_key).empty?

        query = run.search_query
        return if query.blank?

        key = @encodings.key(model, query, tenant_key: run.tenant_key, user_key: run.user_key)
        encoding =
          if @encodings.encoded?(key) then @encodings.read_encoding(key, query)
          elsif @encodings.in_flight?(key) then @encoder.await(key, deadline: @deadline, query: query)
          end
        encoding&.without(run.suppressed, keep_words: -> { Search::Filler.label_words(model.truffler_definition, run.tenant_key) })
      end

      # The snapshot narrowed to what the encoding allows, in the tenant, in
      # the keystroke ranking the encoding gives (or snapshot order without
      # one), capped at `rerank_depth`.
      def filter(run, encoding)
        model = run.model
        pool = model.where(model.primary_key => run.pool_ids)
        sql = Search::Sql.new(model, tenant_key: run.tenant_key, query: run.search_query, encoding: encoding)
        allowed = sql.base(pool).pluck(model.primary_key)
        ids = if encoding.nil? || encoding.empty?
          run.pool_ids & allowed
        else
          ranked = sql.relation(pool).map(&:id)
          ranked + ((run.pool_ids & allowed) - ranked)
        end
        ids.first(@config.rerank_depth)
      end
    end
  end
end
