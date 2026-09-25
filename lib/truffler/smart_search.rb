module Truffler
  # Smart search on explicit action (KTD11-KTD13, R22-R24, R26, R27). The
  # host starts a run; `SmartSearchJob` checks the rerank budget, waits for
  # an in-flight query encoding up to the deadline, re-applies its filters to
  # the candidate snapshot, and fans out one `RerankChunkJob` per chunk. Each
  # chunk's scores append to the Strong, Possible, and Unlikely buckets in
  # arrival order and a data-free ping tells the host to reload.
  module SmartSearch
    BUCKETS = %i[strong possible unlikely].freeze
    COLLAPSED_BY_DEFAULT = %i[unlikely].freeze
    SMART = "smart".freeze
    PROVIDER = "provider".freeze

    module_function

    # Starts a run and returns it, already `reserved?`. See `Starter`.
    def start(model, query, **options)
      Starter.new(model, query, **options).call
    end

    # The run for `run_id`, or an expired run once the cache let it go.
    def find(run_id, store: Store.new)
      Run.find(run_id, store: store)
    end

    # Cancels the current run for (model, tenant, user, surface), as when the
    # searcher edits the query or accepts or removes a chip (R24).
    def cancel(model, tenant:, user:, surface: nil, store: Store.new)
      run_id = store.current_run_id(model.polymorphic_name, tenant&.to_s, Search::Keystroke.user_key(user), surface&.to_s)
      run = run_id && Run.find(run_id, store: store)
      run&.cancel!
      run
    end

    def bucket_for(score, thresholds: Truffler.config.smart_thresholds)
      if score >= thresholds.fetch(:strong) then :strong
      elsif score >= thresholds.fetch(:possible) then :possible
      else :unlikely
      end
    end
  end
end
