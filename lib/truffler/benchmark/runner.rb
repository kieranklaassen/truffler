require "fileutils"

module Truffler
  module Benchmark
    # Loads a dataset into the current database, labels it through the real
    # pipeline (Queue, Labeler, RequestBuilder, Budget) with the given client,
    # and returns one JSON-ready report: the R32 metrics, the R33 packed-batch
    # agreement, the R34 injection result, and the params echo.
    #
    # Modes: :replay reads committed cassettes and never calls out; :record
    # rewrites a cassette directory; :synthetic answers from SyntheticJev with
    # no cassette, for generated datasets of any size.
    class Runner
      MODES = %i[replay record synthetic].freeze
      SOURCES = { synthetic: "synthetic-fake", live: "live" }.freeze
      MANIFEST = "manifest.json".freeze

      attr_reader :params, :dataset, :mode, :source

      def self.build(params: Params.load(Benchmark.path("params.yml")), mode: :replay, jev: :synthetic, records: nil,
        tenants: 3, seed: Generator::DEFAULT_SEED, cassettes: nil, env: ENV, jev_options: {},
        searcher: Adapters.searcher, reranker: Adapters.reranker)
        mode = mode.to_sym
        jev = jev.to_sym
        raise ArgumentError, "MODE must be one of #{MODES.join(', ')}" unless MODES.include?(mode)
        raise ArgumentError, "JEV must be one of #{SOURCES.keys.join(', ')}" unless SOURCES.key?(jev)

        dataset = records ? Generator.new(records: Integer(records), tenants: tenants, seed: seed).dataset : Dataset.load(Benchmark.path("fixtures"))
        cassettes = (cassettes || default_cassettes(jev)).to_s
        client = client_for(mode, jev, dataset, cassettes, env, jev_options)
        new(params: params, dataset: dataset, client: client, mode: mode, source: source_for(mode, jev, cassettes),
          cassettes: (cassettes unless mode == :synthetic), searcher: searcher, reranker: reranker)
      end

      # MODE, JEV, PARAMS, BENCH_RECORDS, BENCH_TENANTS, and CASSETTES from the
      # environment. TRUFFLER_CASSETTE_MODE=record means recording live Jev.
      def self.from_env(env = ENV)
        mode = env["MODE"].presence || env["TRUFFLER_CASSETTE_MODE"].presence || "replay"
        jev = env["JEV"].presence || (env["TRUFFLER_CASSETTE_MODE"] == "record" ? "live" : "synthetic")
        build(params: Params.load(env["PARAMS"].presence || Benchmark.path("params.yml")), mode: mode, jev: jev,
          records: env["BENCH_RECORDS"].presence, tenants: Integer(env["BENCH_TENANTS"].presence || 3),
          cassettes: env["CASSETTES"].presence, env: env)
      end

      def self.default_cassettes(jev)
        jev == :live ? File.join(Dir.pwd, "tmp", "bench", "cassettes-live") : Benchmark.path("cassettes")
      end

      def self.client_for(mode, jev, dataset, cassettes, env, jev_options)
        inner = if jev == :live
          raise ArgumentError, "live Jev needs MODE=record or MODE=replay" if mode == :synthetic
          raise ArgumentError, "recording live Jev needs TYPESAFE_API_KEY" if mode == :record && env["TYPESAFE_API_KEY"].blank?

          Clients::RubyLLMTypeSafe.new if mode == :record
        else
          SyntheticJev.new(dataset, **jev_options)
        end
        return inner if mode == :synthetic

        Clients::Cassette.new(mode == :record ? inner : nil, dir: cassettes, mode: mode)
      end

      def self.source_for(mode, jev, cassettes)
        manifest = File.join(cassettes, MANIFEST)
        return JSON.parse(File.read(manifest)).fetch("source") if mode == :replay && File.exist?(manifest)

        SOURCES.fetch(jev)
      end

      def initialize(params:, dataset:, client:, mode:, source:, cassettes: nil, searcher: Adapters.searcher,
        reranker: Adapters.reranker, model: Email)
        @params = params
        @dataset = dataset
        @client = client
        @mode = mode.to_sym
        @source = source
        @cassettes = cassettes
        @searcher = searcher
        @reranker = reranker
        @model = model
      end

      def run
        check_batch_size!
        prepare_cassettes if mode == :record
        @model.create_table!
        @model.declare!(params)
        load_dataset
        labeling = label_all
        agreement = agreement_check
        injection_labels = injection_label_check
        search, rerank, query_cost = measure_queries

        report(labeling, agreement, injection_labels, search, rerank, query_cost)
      end

      private

      def check_batch_size!
        return if params.batch_size <= Truffler.config.tenant_live_cap

        raise ArgumentError, "labeling.batch_size #{params.batch_size} exceeds tenant_live_cap #{Truffler.config.tenant_live_cap}"
      end

      def prepare_cassettes
        FileUtils.mkdir_p(@cassettes)
        Dir[File.join(@cassettes, "*.json")].each { |file| File.delete(file) }
        File.write(File.join(@cassettes, MANIFEST), "#{Canonical.json(source: source, generator: 'Truffler::Benchmark')}\n")
      end

      def record_type
        @model.polymorphic_name
      end

      def load_dataset
        Records::Label.where(record_type: record_type).delete_all
        Records::RecordState.where(record_type: record_type).delete_all
        now = Time.current
        @dataset.labeled_records.each_slice(1_000) do |slice|
          @model.insert_all!(slice.map do |record|
            { id: record.id, tenant_id: Integer(record.tenant), subject: record.subject, body: record.body,
              sender_name: record.sender_name, sender_email: record.sender_email,
              received_at: Time.iso8601(record.received_at), created_at: now, updated_at: now }
          end)
          Records::RecordState.insert_all!(slice.map do |record|
            { record_type: record_type, record_id: record.id, tenant_key: record.tenant, status: "pending",
              priority: "live", attempts: 0, created_at: now, updated_at: now }
          end)
        end
      end

      # Labels every record at live priority under the account budget on a
      # simulated clock: waits advance the clock, and a tenant over its live
      # cap waits for the next minute, so throughput is what the budget allows.
      def label_all
        clock = SimulatedClock.new
        budget = Budget.new(cache: ActiveSupport::Cache::MemoryStore.new, clock: -> { clock.now }, sleeper: ->(seconds) { clock.advance(seconds) })
        labeler = Labeling::Labeler.new(@model, client: @client, budget: budget)
        queue = Labeling::Queue.new(@model)
        totals = { labeled: 0, requests: 0, cost: 0.0, demotions: 0 }
        pending = @dataset.tenants.dup

        until pending.empty?
          progressed = false
          pending.dup.each do |tenant|
            states = queue.claim(tenant, priority: :live, limit: params.batch_size)
            next pending.delete(tenant) if states.empty?

            result = labeler.label(states, priority: :live)
            if result.demoted
              totals[:demotions] += 1
              Records::RecordState.where(id: states.map(&:id)).update_all(status: "pending", claimed_at: nil)
            else
              progressed = true
              totals[:labeled] += result.labeled
              totals[:requests] += result.requests
              totals[:cost] += result.cost
            end
          end
          clock.next_minute unless progressed || pending.empty?
        end

        minutes = [ clock.elapsed.ceil, 1 ].max / 60.0
        totals.merge(minutes: minutes, budget: budget)
      end

      def agreement_check
        tolerance = params.dig(:labeling, :agreement_tolerance)
        floor = params.dig(:labeling, :agreement_floor)
        sample = agreement_sample
        results = params.agreement_batch_sizes.to_h { |size| [ size, label_values(sample, size) ] }
        single = results.fetch(1)[:values]

        sizes = results.to_h do |size, result|
          compared = Metrics.agreement(single, result[:values], tolerance: tolerance)
          [ size.to_s, { "agreement" => compared[:agreement].round(4), "adoptable" => Metrics.adoptable?(compared[:agreement], floor: floor),
                         "requests" => result[:requests], "disagreements" => compared[:disagreements].size } ]
        end
        adopted = sizes.select { |_, entry| entry["adoptable"] }.keys.map(&:to_i).max
        { "tolerance" => tolerance, "floor" => floor, "sample" => sample.values.sum(&:size), "batch_sizes" => sizes,
          "adopted_batch_size" => adopted }
      end

      def agreement_sample
        per_tenant = params.dig(:labeling, :agreement_sample_per_tenant)
        ids = @dataset.records.group_by(&:tenant).transform_values { |records| records.first(per_tenant).map(&:id) }
        ids.transform_values { |tenant_ids| @model.where(id: tenant_ids).order(:id).to_a }
      end

      def label_values(sample, size)
        definition = @model.truffler_definition
        values = Hash.new { |hash, key| hash[key] = {} }
        requests = 0
        sample.each do |tenant, records|
          builder = Labeling::RequestBuilder.new(definition, tenant_key: tenant)
          records.each_slice(size) do |chunk|
            builder.build(chunk.map { |record| [ record, definition.label_keys ] }).each do |request|
              requests += 1
              answers = @client.ask(state: request.state, questions: request.questions, priority: :backfill)
              request.entries.each do |tag, (record, keys)|
                keys.each { |key| values[record.id][key] = answer_value(definition.label(key), answers, Questions.tagged_id(tag, key)) }
              end
            end
          end
        end
        { values: values, requests: requests }
      end

      def answer_value(label, answers, id)
        case label.type
        when :noul then answers.noul(id)
        when :score then answers.score(id)
        when :choice then answers.choice(id)
        end
      end

      def injection_label_check
        tolerance = params.dig(:injection, :label_tolerance)
        ids = @dataset.injections.flat_map { |injection| [ injection.clean_id, injection.record.id ] }
        stored = Records::Label.where(record_type: record_type, record_id: ids).pluck(:record_id, :label_key, :value)
          .each_with_object(Hash.new { |hash, key| hash[key] = {} }) { |(id, key, value), map| map[id][key] = value }

        failures = @dataset.injections.filter_map do |injection|
          clean = stored[injection.clean_id]
          twin = stored[injection.record.id]
          changed = (clean.keys | twin.keys).reject { |key| Metrics.agree?(clean.fetch(key, 0.0), twin.fetch(key, 0.0), tolerance) }
          next if changed.empty?

          { "fixture" => injection.id, "clean_id" => injection.clean_id, "twin_id" => injection.record.id,
            "labels" => changed.map { |key| key.split(":").first }.uniq.sort }
        end
        { "passed" => failures.empty?, "tolerance" => tolerance, "twins" => @dataset.injections.size, "failures" => failures }
      end

      def measure_queries
        cost = 0.0
        counter = ->(*, payload) { cost += payload[:cost].to_f }
        search = rerank = nil
        ActiveSupport::Notifications.subscribed(counter, "truffler.jev_call") do
          search = search_metrics
          rerank = rerank_metrics(search)
        end
        query_cost = Benchmark.not_available?(search) ? search : (cost / @dataset.gold.size).round(8)
        [ search, rerank, query_cost ]
      end

      def search_metrics
        return @searcher if Benchmark.not_available?(@searcher)

        returned = {}
        latencies = []
        @dataset.gold.each do |gold|
          started = Instrumentation.monotonic_ms
          ids = @searcher.call(query: gold.query, tenant_key: gold.tenant, kind: gold.kind, model: @model, params: params)
          return ids if Benchmark.not_available?(ids)

          latencies << Instrumentation.monotonic_ms - started
          returned[gold.id] = ids.to_a
        end

        by_kind = @dataset.gold.group_by(&:kind)
        score = ->(metric) { by_kind.transform_values { |golds| Metrics.mean(golds.map { |gold| Metrics.public_send(metric, gold.expected_ids, returned[gold.id]) }).round(4) } }
        { "recall" => score.(:recall), "precision" => score.(:precision),
          "latency" => { "p50" => Metrics.percentile(latencies, 50).round(3), "p95" => Metrics.percentile(latencies, 95).round(3) },
          "returned" => returned }
      end

      def rerank_metrics(search)
        return @reranker if Benchmark.not_available?(@reranker)
        return search if Benchmark.not_available?(search)

        depth = params.rerank_depth
        requests = 0
        buckets = Hash.new(0)
        @dataset.gold.select { |gold| gold.kind == "intent" }.each do |gold|
          result = rerank(gold.query, gold.tenant, search["returned"].fetch(gold.id), depth)
          return result if Benchmark.not_available?(result)

          requests += result[:requests]
          result[:buckets].each_value { |bucket| buckets[bucket.to_s] += 1 }
        end
        { "depth" => depth, "requests" => requests, "buckets" => buckets.sort.to_h, "injection" => rerank_injection_check(depth) }
      end

      def rerank(query, tenant, candidate_ids, depth)
        @reranker.call(query: query, tenant_key: tenant, model: @model, candidate_ids: candidate_ids.first(depth), depth: depth, params: params,
          client: @client)
      end

      def rerank_injection_check(depth)
        failures = @dataset.injections.filter_map do |injection|
          buckets = rerank(injection.query, injection.record.tenant, [ injection.clean_id, injection.record.id ], depth)
          return buckets if Benchmark.not_available?(buckets)
          next if buckets[:buckets][injection.clean_id].to_s == buckets[:buckets][injection.record.id].to_s

          { "fixture" => injection.id, "clean_id" => injection.clean_id, "twin_id" => injection.record.id }
        end
        { "passed" => failures.empty?, "failures" => failures }
      end

      def report(labeling, agreement, injection_labels, search, rerank, query_cost)
        injection_rerank = Benchmark.not_available?(rerank) ? rerank : rerank.delete("injection")
        failures = []
        failures << "injection_labels" unless injection_labels["passed"]
        failures << "injection_rerank" if injection_rerank.is_a?(Hash) && injection_rerank["passed"] == false
        failures << "batch_size_agreement" unless agreement["batch_sizes"].fetch(params.batch_size.to_s)["adoptable"]

        report = {
          "truffler_bench" => REPORT_VERSION,
          "source" => source,
          "mode" => mode.to_s,
          "params" => params.to_h,
          "dataset" => @dataset.summary,
          "metrics" => {
            "recall" => per_kind(search, "recall"),
            "precision" => per_kind(search, "precision"),
            "keystroke_latency_ms" => Benchmark.not_available?(search) ? search : search["latency"],
            "labeling_throughput" => throughput(labeling),
            "cost" => { "per_labeled_record" => (labeling[:cost] / [ labeling[:labeled], 1 ].max).round(8), "per_query" => query_cost }
          },
          "agreement" => agreement,
          "injection" => { "labels" => injection_labels, "rerank" => injection_rerank },
          "rerank" => rerank,
          "checks" => { "passed" => failures.empty?, "failures" => failures }
        }
        JSON.parse(JSON.generate(report.as_json))
      end

      def per_kind(search, metric)
        return { "intent" => search, "exact_text" => search } if Benchmark.not_available?(search)

        search[metric]
      end

      def throughput(labeling)
        budget = labeling[:budget]
        { "records" => labeling[:labeled], "requests" => labeling[:requests],
          "records_per_request" => (labeling[:labeled] / [ labeling[:requests], 1 ].max.to_f).round(3),
          "simulated_minutes" => labeling[:minutes].round(4),
          "requests_per_minute" => (labeling[:requests] / labeling[:minutes]).round(2),
          "records_per_minute" => (labeling[:labeled] / labeling[:minutes]).round(2),
          "tenant_demotions" => labeling[:demotions],
          "budget_live_requests_per_minute" => (budget.ceiling(:live) * 60).round(2),
          "tenant_live_cap" => Truffler.config.tenant_live_cap }
      end

      class SimulatedClock
        START = 1_800_000_000.0

        attr_reader :now

        def initialize
          @now = START
        end

        def advance(seconds)
          @now += seconds
        end

        def next_minute
          @now = ((@now / 60).floor + 1) * 60.0
        end

        def elapsed
          @now - START
        end
      end
    end
  end
end
