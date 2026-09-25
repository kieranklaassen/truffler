require "test_helper"
require "tmpdir"

class BenchmarkRunnerTest < Truffler::TestCase
  Bench = Truffler::Benchmark
  R32_KEYS = %w[recall precision keystroke_latency_ms labeling_throughput cost].freeze

  class StubSearcher
    attr_reader :calls

    def initialize(dataset)
      @expected = dataset.gold.to_h { |gold| [ [ gold.query, gold.tenant ], gold.expected_ids ] }
      @calls = []
    end

    def call(query:, tenant_key:, kind:, **)
      @calls << { query: query, tenant_key: tenant_key }
      ids = @expected.fetch([ query, tenant_key ])
      kind == "exact_text" ? ids.first(1) : ids
    end
  end

  class StubReranker
    CHUNK = 5

    def call(candidate_ids:, depth:, **)
      ids = candidate_ids.first(depth)
      { requests: (ids.size / CHUNK.to_f).ceil, buckets: ids.to_h { |id| [ id, "strong" ] } }
    end
  end

  def params(overrides = {})
    Bench::Params.load(Bench.path("params.yml"), overrides: overrides)
  end

  def run_bench(**options)
    Bench::Runner.build(params: options.delete(:params) || params, **options).run
  end

  test "a replay over the committed fixtures emits every R32 metric, R33 agreement, R34 injection, and the params echo" do
    report = run_bench(mode: :replay)

    assert_equal "synthetic-fake", report["source"]
    assert_equal "replay", report["mode"]
    assert_equal R32_KEYS.sort, (report["metrics"].keys & R32_KEYS).sort
    assert_equal params.to_h, report["params"]
    assert_equal({ "records" => 90, "tenants" => 3, "gold" => { "intent" => 18, "exact_text" => 9 }, "injection_twins" => 6 },
      report["dataset"].slice("records", "tenants", "gold", "injection_twins"))

    throughput = report["metrics"]["labeling_throughput"]
    assert_equal 96, throughput["records"]
    assert_operator throughput["records_per_request"], :>, 1
    assert_operator throughput["requests_per_minute"], :>, 0
    assert_operator report["metrics"]["cost"]["per_labeled_record"], :>, 0

    assert_equal %w[1 5 10 20], report["agreement"]["batch_sizes"].keys
    assert_equal 1.0, report["agreement"]["batch_sizes"]["1"]["agreement"]
    assert report["injection"]["labels"]["passed"]
    assert report["checks"]["passed"], report["checks"].inspect
    assert_equal report, JSON.parse(JSON.generate(report))
  end

  test "search, rerank, and query cost report not-available markers until U8 and U10 load" do
    report = run_bench(mode: :replay, searcher: Bench::NotAvailable.new("U8 keystroke search"),
      reranker: Bench::NotAvailable.new("U10 Smart search"))

    marker = { "status" => "not_available_yet", "requires" => "U8 keystroke search" }
    assert_equal marker, report["metrics"]["recall"]["intent"]
    assert_equal marker, report["metrics"]["precision"]["exact_text"]
    assert_equal marker, report["metrics"]["keystroke_latency_ms"]
    assert_equal marker, report["metrics"]["cost"]["per_query"]
    assert_equal({ "status" => "not_available_yet", "requires" => "U10 Smart search" }, report["rerank"])
    assert_equal "not_available_yet", report["injection"]["rerank"]["status"]
    assert Bench.not_available?(report["rerank"])
    assert report["checks"]["passed"]
  end

  test "the default adapters are markers while the search and smart namespaces are absent" do
    assert Bench.not_available?(Bench::Adapters.searcher(loaded: -> { false }))
    assert_match(/U8/, Bench::Adapters.searcher(loaded: -> { false }).requires)
    assert_match(/U10/, Bench::Adapters.reranker(loaded: -> { false }).requires)
    assert_kind_of Bench::Adapters::Keystroke, Bench::Adapters.searcher(loaded: -> { true })
    assert_kind_of Bench::Adapters::Smart, Bench::Adapters.reranker(loaded: -> { true })
  end

  test "a plugged-in searcher lights up recall, precision, latency, and query cost" do
    searcher = StubSearcher.new(Bench::Dataset.load(Bench.path("fixtures")))

    report = run_bench(mode: :replay, searcher: searcher)

    metrics = report["metrics"]
    assert_in_delta 1.0, metrics["recall"]["intent"]
    assert_in_delta 1.0, metrics["precision"]["intent"]
    assert_operator metrics["recall"]["exact_text"], :<=, 1.0
    assert_in_delta 1.0, metrics["precision"]["exact_text"]
    assert_operator metrics["keystroke_latency_ms"]["p95"], :>=, metrics["keystroke_latency_ms"]["p50"]
    assert_in_delta 0.0, metrics["cost"]["per_query"]
    assert_equal 27, searcher.calls.size
    assert_equal %w[1 2 3], searcher.calls.map { |call| call[:tenant_key] }.uniq.sort
  end

  test "a params file changing rerank depth to 10 shows in the echo and in the rerank request count" do
    searcher = StubSearcher.new(Bench::Dataset.load(Bench.path("fixtures")))
    deep = run_bench(mode: :replay, searcher: searcher, reranker: StubReranker.new)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "params.yml")
      File.write(path, { "rerank" => { "depth" => 10 } }.to_yaml)
      shallow = run_bench(mode: :replay, params: Bench::Params.load(path), searcher: searcher, reranker: StubReranker.new)

      assert_equal 10, shallow["params"]["rerank"]["depth"]
      assert_equal 30, deep["params"]["rerank"]["depth"]
      assert_operator shallow["rerank"]["requests"], :<, deep["rerank"]["requests"]
      assert_equal 10, shallow["rerank"]["depth"]
    end
  end

  test "a replay miss fails the run with the cassette hash and attempts no live call" do
    Dir.mktmpdir do |dir|
      error = assert_raises(Truffler::CassetteMiss) { run_bench(mode: :replay, cassettes: dir) }

      assert_match(/no recording \h{64} in #{Regexp.escape(dir)}/, error.message)
    end
  end

  test "an injection twin labeled differently from its clean twin fails R34 and names the fixture" do
    report = run_bench(mode: :synthetic, jev_options: { obey_injections: true })

    labels = report["injection"]["labels"]
    assert_not labels["passed"]
    assert_equal 6, labels["failures"].size
    failure = labels["failures"].first
    assert_match(/\Ainj-\d+-\d+\z/, failure["fixture"])
    assert_includes failure["labels"], "needs_action"
    assert_not report["checks"]["passed"]
    assert_includes report["checks"]["failures"], "injection_labels"
  end

  test "a batch size whose agreement is below the floor is not adoptable and fails the check when configured" do
    report = run_bench(mode: :synthetic, params: params("labeling" => { "batch_size" => 20 }))

    sizes = report["agreement"]["batch_sizes"]
    assert_not sizes["20"]["adoptable"], sizes.inspect
    assert sizes["5"]["adoptable"]
    assert_equal sizes.select { |_, entry| entry["adoptable"] }.keys.map(&:to_i).max, report["agreement"]["adopted_batch_size"]
    assert_includes report["checks"]["failures"], "batch_size_agreement"
  end

  test "record mode writes cassettes and a manifest that a later replay reads" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "stale.json"), "{}")
      recorded = run_bench(mode: :record, cassettes: dir)
      replayed = run_bench(mode: :replay, cassettes: dir)

      assert_not File.exist?(File.join(dir, "stale.json"))
      assert_equal({ "source" => "synthetic-fake" }, JSON.parse(File.read(File.join(dir, "manifest.json"))).slice("source"))
      assert_equal recorded["metrics"]["labeling_throughput"], replayed["metrics"]["labeling_throughput"]
      assert_equal "record", recorded["mode"]
    end
  end

  test "recording against live Jev needs a TypeSafe key" do
    error = assert_raises(ArgumentError) { Bench::Runner.build(mode: :record, jev: :live, params: params, env: {}) }

    assert_match(/TYPESAFE_API_KEY/, error.message)
  end

  test "the environment picks replay by default and treats TRUFFLER_CASSETTE_MODE=record as live recording" do
    runner = Bench::Runner.from_env({})

    assert_equal :replay, runner.mode
    assert_equal "synthetic-fake", runner.source
    assert_raises(ArgumentError, match: /TYPESAFE_API_KEY/) { Bench::Runner.from_env("TRUFFLER_CASSETTE_MODE" => "record") }
    assert_raises(ArgumentError, match: /unknown benchmark param/) do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "params.yml"), { "search" => { "boost" => {} } }.to_yaml)
        Bench::Runner.from_env("PARAMS" => File.join(dir, "params.yml"))
      end
    end
  end

  test "a generated Cora-scale dataset runs in synthetic mode" do
    report = run_bench(mode: :synthetic, records: 240)

    assert_equal 240, report["dataset"]["records"]
    assert_equal "synthetic-fake", report["source"]
    assert_equal 246, report["metrics"]["labeling_throughput"]["records"]
    assert report["checks"]["passed"], report["checks"].inspect
  end
end
