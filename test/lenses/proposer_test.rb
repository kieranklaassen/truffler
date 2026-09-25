require "test_helper"

class ProposerTest < Truffler::TestCase
  include Truffler::Test::LensHelpers

  Proposer = Truffler::Lenses::Proposer

  setup do
    Truffler.config.lenses.proposals = true
  end

  def miss(query, user:, tenant: "1")
    Truffler::Misses.record(FeedMessage, tenant_key: tenant, user_key: user, query: query)
  end

  test "nothing is proposed while proposals are off" do
    Truffler.config.lenses.proposals = false
    5.times { |i| miss("dutch recipes", user: "u#{i}") }

    assert_empty Proposer.propose(FeedMessage, tenant_key: "1")
    assert_empty @generator.calls
  end

  test "a cluster below the distinct-user gate is never proposed; above it a proposed lens changes nothing until approved" do
    4.times { |i| miss("dutch recipes", user: "u#{i}") }
    assert_empty Proposer.propose(FeedMessage, tenant_key: "1")
    assert_empty @generator.calls

    miss("Dutch recipes please", user: "u4")
    lens = Proposer.propose(FeedMessage, tenant_key: "1").sole

    assert_equal "proposed", lens.status
    assert_equal "proposal", lens.origin
    assert_equal Truffler::Lenses::Scope.tenant("1"), lens.scope
    assert_equal "feed messages about dutch and recipe", lens.description
    assert_equal "draft", lens.versions.sole.status
    assert_nil lens.versions.sole.created_by_digest
    assert_empty Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1")

    assert_raises(Truffler::NotAuthorized) { Truffler::Lenses::Activator.activate(lens, by: member) }
    Truffler::Lenses::Activator.activate(lens, by: admin)
    assert_equal [ "lens:#{lens.id}:matches_lens" ], Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1").keys
  end

  test "the drafting model sees aggregated cluster terms and counts, never raw queries or user digests" do
    5.times { |i| miss("dutch recipes from grandma #{i}", user: "u#{i}") }

    Proposer.propose(FeedMessage, tenant_key: "1")
    prompt = @generator.calls.sole[:prompt]
    request = JSON.parse(prompt)

    cluster = request["miss_clusters"].sole
    assert_equal %w[distinct_users query_count terms], cluster.keys.sort
    assert_equal [ 5, 5 ], cluster.values_at("query_count", "distinct_users")
    assert_includes cluster["terms"], "dutch"
    assert_not_includes prompt, Truffler::Misses.digest(:user, "u0")
    assert_not_includes prompt, "recipes from grandma 0"
  end

  test "a cluster is proposed once, and pooled tenants propose app lenses" do
    5.times { |i| miss("dutch recipes", user: "u#{i}") }

    assert_equal 1, Proposer.propose(FeedMessage, tenant_key: "1").size
    assert_empty Proposer.propose(FeedMessage, tenant_key: "1")

    app = Proposer.propose(FeedMessage, tenant_key: Truffler::Misses::ALL_TENANTS).sole
    assert_equal "app", app.scope_type
    assert_equal 2, Truffler::Lenses::Lens.proposed.count
  end
end
