module Truffler
  module Benchmark
    # Search and rerank are measured through adapters so the benchmark runs
    # before keystroke search (U8) and Smart runs (U10) exist. Until their
    # namespaces load, the defaults are NotAvailable markers; any object with
    # the same `call` signature can be passed to Runner instead.
    #
    #   searcher.call(query:, tenant_key:, kind:, model:, params:) => ranked ids
    #   reranker.call(query:, tenant_key:, model:, candidate_ids:, depth:, params:, client:)
    #     => { requests: Integer, buckets: { id => bucket } }
    module Adapters
      USER = "truffler-bench".freeze

      module_function

      def searcher(loaded: -> { namespace?(:Search) })
        loaded.call ? Keystroke.new : NotAvailable.new("U8 keystroke search (Truffler::Search)")
      end

      def reranker(loaded: -> { namespace?(:SmartSearch) })
        loaded.call ? Smart.new : NotAvailable.new("U10 Smart search runs (Truffler::SmartSearch)")
      end

      def namespace?(name)
        Truffler.const_defined?(name, false)
      end

      class Keystroke
        def call(query:, tenant_key:, model:, **)
          scope = model.where(model.truffler_definition.tenant_column => tenant_key)
          model.truffler(query, tenant: tenant_key, scope: scope, user: USER).records.map(&:id)
        end
      end

      # Runs a Smart search inline: the run starts, plans, and reranks each
      # chunk in this thread under an unmetered budget, without waiting for
      # query encoding, so a replay is deterministic. Rerank requests are
      # counted from the jev_call notifications.
      class Smart
        Unmetered = Struct.new(:priority) do
          def acquire(priority:, **)
            Truffler::Budget::Decision.new(:granted, priority, nil)
          end
          alias_method :admit, :acquire
        end

        NoEncodings = Struct.new(:none) do
          def key(*, **) = nil
          def encoded?(*) = false
          def in_flight?(*) = false
        end

        def call(query:, tenant_key:, model:, candidate_ids:, client: Truffler.config.client, **)
          requests = 0
          counter = ->(*, payload) { requests += 1 if payload[:priority].to_s == "rerank" }
          run = ActiveSupport::Notifications.subscribed(counter, "truffler.jev_call") do
            SmartSearch.start(model, query, tenant: tenant_key, scope: model.where(id: candidate_ids), user: USER, dispatch: dispatcher(client))
          end

          { requests: requests, buckets: bucket_by_id(run.buckets) }
        end

        private

        def dispatcher(client)
          reranker = SmartSearch::Reranker.new(client: client, budget: Unmetered.new)
          dispatcher = SmartSearch::Dispatcher.new(budget: Unmetered.new, encodings: NoEncodings.new, deadline: 0,
            enqueue: ->(run, index) { reranker.call(run, index) })
          ->(run) { dispatcher.call(run) }
        end

        def bucket_by_id(buckets)
          buckets.to_h.each_with_object({}) do |(bucket, entries), map|
            Array(entries).each { |entry| map[entry.is_a?(Hash) ? entry.with_indifferent_access[:id] : entry] = bucket.to_s }
          end
        end
      end
    end
  end
end
