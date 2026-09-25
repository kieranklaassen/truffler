require "test_helper"

class BudgetTest < Truffler::TestCase
  class FakeClock
    attr_accessor :now
    attr_reader :sleeps

    def initialize(now)
      @now = now
      @sleeps = []
    end

    def call
      now
    end

    def sleep(seconds)
      @sleeps << seconds
      @now += seconds
    end
  end

  setup { @clock = FakeClock.new(960.2) }

  def budget(per_minute: 1_200, cache: ActiveSupport::Cache::MemoryStore.new)
    Truffler.config.requests_per_minute = per_minute
    Truffler::Budget.new(cache: cache, clock: @clock, sleeper: @clock.method(:sleep))
  end

  test "headroom 0.25 leaves 900 of 1,200 requests a minute for the gem" do
    assert_equal 900, budget.gem_per_minute
  end

  test "a live acquire over the second's share waits for the next second" do
    budget = budget(per_minute: 160)

    2.times { assert budget.acquire(priority: :live).granted? }
    decision = budget.acquire(priority: :live)

    assert decision.granted?
    assert_equal 1, @clock.sleeps.size
    assert_in_delta 0.8, @clock.sleeps.first
  end

  test "a live acquire that cannot get a slot within max_wait is denied" do
    Truffler.config.max_wait = 0.5
    budget = budget(per_minute: 160)

    2.times { budget.acquire(priority: :live) }
    decision = budget.acquire(priority: :live)

    assert decision.denied?
    assert_equal :exhausted, decision.reason
    assert_empty @clock.sleeps
  end

  test "backfill is denied at half the share while live is still granted" do
    budget = budget(per_minute: 160)

    assert budget.acquire(priority: :live).granted?
    assert budget.acquire(priority: :backfill).denied?
    assert budget.acquire(priority: :live).granted?
    assert_empty @clock.sleeps
  end

  test "priority order holds under a filled second" do
    budget = budget(per_minute: 1_600)

    15.times { assert budget.acquire(priority: :live).granted? }
    assert budget.acquire(priority: :backfill).denied?
    assert budget.acquire(priority: :rerank).denied?
    3.times { assert budget.acquire(priority: :encode).granted? }
    assert budget.acquire(priority: :encode).denied?
    2.times { assert budget.acquire(priority: :live).granted? }
  end

  test "0.1.2: a denial carries a retry hint: the next second for a full second, the next minute for a user cap" do
    budget = budget(per_minute: 160)
    budget.acquire(priority: :live)

    exhausted = budget.acquire(priority: :backfill)
    assert_in_delta 0.8, exhausted.retry_after, 1e-9

    Truffler.config.user_caps = { rerank: 1 }
    budget.admit(priority: :rerank, user_key: "ann")
    capped = budget.admit(priority: :rerank, user_key: "ann")
    assert_in_delta 59.8, capped.retry_after, 1e-9
    assert_nil budget.acquire(priority: :live).retry_after
  end

  test "denied callers do not consume a slot" do
    budget = budget(per_minute: 160)

    budget.acquire(priority: :live)
    3.times { budget.acquire(priority: :backfill) }

    assert budget.acquire(priority: :live).granted?
    assert_empty @clock.sleeps
  end

  test "admit counts against the per-user cap without taking a request slot" do
    budget = budget(per_minute: 60)
    assert_equal 1, budget.ceiling(:rerank)

    10.times { assert budget.admit(priority: :rerank, user_key: "ann").granted? }
    decision = budget.admit(priority: :rerank, user_key: "ann")

    assert decision.denied?
    assert_equal :user_cap, decision.reason
    assert budget.acquire(priority: :rerank).granted?, "admits took no per-second slot"
    assert budget.admit(priority: :rerank, user_key: "bob").granted?
  end

  test "a user over 10 reruns a minute is denied while another user is granted" do
    budget = budget()

    10.times do
      assert budget.acquire(priority: :rerank, user_key: "ann").granted?
      @clock.now += 1
    end
    decision = budget.acquire(priority: :rerank, user_key: "ann")

    assert decision.denied?
    assert_equal :user_cap, decision.reason
    assert budget.acquire(priority: :rerank, user_key: "bob").granted?
  end

  test "a user over 30 encodings a minute is denied" do
    budget = budget()

    30.times do
      assert budget.acquire(priority: :encode, user_key: "ann").granted?
      @clock.now += 1
    end

    assert budget.acquire(priority: :encode, user_key: "ann").denied?
  end

  test "a tenant past its live cap is demoted while other tenants keep encoding and reranking" do
    budget = budget()

    assert budget.acquire(priority: :live, tenant_key: "spammed", records: 120).granted?
    decision = budget.acquire(priority: :live, tenant_key: "spammed", records: 5)

    assert decision.demoted?
    assert_equal :backfill, decision.priority
    assert_equal :tenant_cap, decision.reason
    assert budget.acquire(priority: :encode, user_key: "other", tenant_key: "quiet").granted?
    assert budget.acquire(priority: :rerank, user_key: "other", tenant_key: "quiet").granted?
    assert budget.acquire(priority: :live, tenant_key: "quiet", records: 10).granted?
  end

  test "the tenant cap resets the next minute" do
    budget = budget()

    budget.acquire(priority: :live, tenant_key: "busy", records: 120)
    @clock.now += 60

    assert budget.acquire(priority: :live, tenant_key: "busy", records: 1).granted?
  end

  test "a cache that cannot count never blocks" do
    budget = budget(per_minute: 60, cache: ActiveSupport::Cache::NullStore.new)

    100.times { assert budget.acquire(priority: :backfill, user_key: "ann", tenant_key: "t").granted? }
  end

  test "denials emit budget_denied with the priority only" do
    budget = budget(per_minute: 160)
    budget.acquire(priority: :live)

    payloads = capture_notifications("truffler.budget_denied") do
      budget.acquire(priority: :backfill, user_key: "ann", tenant_key: "t")
    end

    assert_equal [ { priority: :backfill } ], payloads
  end

  test "rejects unknown priorities" do
    assert_raises(ArgumentError) { budget.acquire(priority: :urgent) }
  end
end
