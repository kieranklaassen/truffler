module Truffler
  module Benchmark
    # Search and rerank are measured through adapters so the benchmark runs
    # before keystroke search (U8) and Smart runs (U10) exist. Until their
    # namespaces load, the defaults are NotAvailable markers; any object with
    # the same `call` signature can be passed to Runner instead.
    #
    #   searcher.call(query:, tenant_key:, kind:, model:, params:) => ranked ids
    #   reranker.call(query:, tenant_key:, model:, candidate_ids:, depth:, params:)
    #     => { requests: Integer, buckets: { id => bucket } }
    module Adapters
      USER = "truffler-bench".freeze

      module_function

      def searcher(loaded: -> { namespace?(:Search) })
        loaded.call ? Keystroke.new : NotAvailable.new("U8 keystroke search (Truffler::Search)")
      end

      def reranker(loaded: -> { namespace?(:Smart) })
        loaded.call ? Smart.new : NotAvailable.new("U10 Smart search runs (Truffler::Smart)")
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

      # Runs a Smart search with jobs performed inline and counts the rerank
      # requests from the jev_call notifications.
      class Smart
        def call(query:, tenant_key:, model:, candidate_ids:, **)
          requests = 0
          counter = ->(*, payload) { requests += 1 if payload[:priority].to_s == "rerank" }
          run = ActiveSupport::Notifications.subscribed(counter, "truffler.jev_call") do
            inline_jobs { model.jev_smart_search(query, tenant: tenant_key, scope: model.where(id: candidate_ids), user: USER, surface: nil) }
          end
          return NotAvailable.new("U10 Smart runs exposing #buckets") unless run.respond_to?(:buckets)

          { requests: requests, buckets: bucket_by_id(run.buckets) }
        end

        private

        def inline_jobs
          previous = ActiveJob::Base.queue_adapter
          ActiveJob::Base.queue_adapter = :inline
          yield
        ensure
          ActiveJob::Base.queue_adapter = previous
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
