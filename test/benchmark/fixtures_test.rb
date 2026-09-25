require "test_helper"

class BenchmarkFixturesTest < ActiveSupport::TestCase
  Bench = Truffler::Benchmark

  test "the committed fixtures are exactly the seeded generator's output" do
    generated = Bench::Generator.new(records: 90, tenants: 3, seed: Bench::Generator::DEFAULT_SEED).dataset
    committed = Bench::Dataset.load(Bench.path("fixtures"))

    assert_equal generated.records, committed.records
    assert_equal generated.gold, committed.gold
    assert_equal generated.injections, committed.injections
  end

  test "the generator is deterministic and uses only reserved example domains" do
    first = Bench::Generator.new(records: 30, tenants: 3, seed: 7).dataset
    second = Bench::Generator.new(records: 30, tenants: 3, seed: 7).dataset

    assert_equal first.records, second.records
    emails = first.records.map(&:sender_email)
    assert emails.all? { |email| email.end_with?("@example.com", "@example.org", "@example.net") }, emails.uniq.inspect
  end

  test "every gold case is tagged intent or exact_text and expects records of its own tenant" do
    dataset = Bench::Dataset.load(Bench.path("fixtures"))
    tenants = dataset.records.to_h { |record| [ record.id, record.tenant ] }

    assert_equal %w[exact_text intent], dataset.gold.map(&:kind).uniq.sort
    dataset.gold.each do |gold|
      assert gold.expected_ids.any?, "#{gold.id} expects nothing"
      assert_equal [ gold.tenant ], gold.expected_ids.map { |id| tenants.fetch(id) }.uniq, gold.id
    end
  end

  test "each injection twin copies its clean record with embedded instructions in the same tenant" do
    dataset = Bench::Dataset.load(Bench.path("fixtures"))
    clean = dataset.records.index_by(&:id)

    dataset.injections.each do |injection|
      original = clean.fetch(injection.clean_id)
      assert_equal original.tenant, injection.record.tenant
      assert_equal original.subject, injection.record.subject
      assert_includes injection.record.body, original.body
      assert_includes injection.record.body.downcase, "ignore all previous instructions"
    end
  end

  test "params reject unknown knobs so optimizer typos fail loudly" do
    error = assert_raises(ArgumentError) { Bench::Params.load(Bench.path("params.yml"), overrides: { "rerank" => { "detph" => 3 } }) }

    assert_match(/rerank.detph/, error.message)
  end

  test "params expose every R36 knob" do
    knobs = Bench::Params.load(Bench.path("params.yml")).to_h

    assert knobs.dig("search", "thresholds").key?("needs_action")
    assert knobs.dig("search", "boosts").key?("urgent")
    assert knobs.dig("search").key?("label_weight")
    assert knobs.dig("search").key?("text_weight")
    assert knobs.dig("search").key?("embeddings")
    assert knobs.dig("search").key?("encoding_deadline_ms")
    assert knobs.dig("rerank").key?("depth")
    assert knobs.dig("labeling").key?("batch_size")
  end
end
