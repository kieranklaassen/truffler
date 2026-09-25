require "test_helper"

class BenchmarkMetricsTest < ActiveSupport::TestCase
  Metrics = Truffler::Benchmark::Metrics

  test "recall and precision against the expected ids" do
    assert_in_delta 0.5, Metrics.recall([ 1, 2 ], [ 1 ])
    assert_in_delta 1.0, Metrics.precision([ 1, 2 ], [ 1 ])
    assert_in_delta 0.5, Metrics.precision([ 1 ], [ 1, 3 ])
  end

  test "empty sets: nothing expected and nothing returned is perfect, nothing returned otherwise scores zero" do
    assert_in_delta 1.0, Metrics.recall([], [])
    assert_in_delta 1.0, Metrics.precision([], [])
    assert_in_delta 0.0, Metrics.recall([ 1 ], [])
    assert_in_delta 0.0, Metrics.precision([ 1 ], [])
  end

  test "nearest-rank percentiles" do
    values = (1..100).to_a.shuffle(random: Random.new(1))

    assert_equal 95, Metrics.percentile(values, 95)
    assert_equal 50, Metrics.percentile(values, 50)
    assert_equal 7, Metrics.percentile([ 7 ], 95)
    assert_nil Metrics.percentile([], 50)
  end

  test "agreement: a packed noul off by 0.3 on 10% of records is 0.9 and not adoptable" do
    single = (1..10).to_h { |id| [ id, { "spam" => 0.2 } ] }
    packed = single.merge(10 => { "spam" => 0.5 })

    result = Metrics.agreement(single, packed, tolerance: 0.15)

    assert_in_delta 0.9, result[:agreement]
    assert_equal 10, result[:compared]
    assert_equal [ { record_id: 10, label: "spam" } ], result[:disagreements]
    assert_not Metrics.adoptable?(result[:agreement], floor: 0.95)
    assert Metrics.adoptable?(0.95, floor: 0.95)
  end

  test "agreement treats a delta of exactly the tolerance as agreeing and compares choices by pick" do
    single = { 1 => { "spam" => 0.80, "tone" => "calm" }, 2 => { "spam" => 0.1, "tone" => "calm" } }
    packed = { 1 => { "spam" => 0.65, "tone" => "calm" }, 2 => { "spam" => 0.1, "tone" => "angry" } }

    result = Metrics.agreement(single, packed, tolerance: 0.15)

    assert_in_delta 0.75, result[:agreement]
    assert_equal [ { record_id: 2, label: "tone" } ], result[:disagreements]
  end

  test "a label missing from the packed answers counts as a disagreement" do
    result = Metrics.agreement({ 1 => { "spam" => 0.2 } }, { 1 => {} }, tolerance: 0.15)

    assert_in_delta 0.0, result[:agreement]
  end
end
