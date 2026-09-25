require "test_helper"
require "rake"

class SuggestionsTest < Truffler::TestCase
  Suggestions = Truffler::Misses::Suggestions

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
  end

  def miss(query, user:, tenant: "1", model: Email)
    Truffler::Misses.record(model, tenant_key: tenant, user_key: user, query: query)
  end

  test "a cluster from 4 distinct users is not suggested and 5 users make it appear" do
    4.times { |i| miss("dutch recipes", user: "u#{i}") }
    assert_empty Suggestions.for(Email, tenant_key: "1")

    miss("Dutch recipes please", user: "u4")
    suggestion = Suggestions.for(Email, tenant_key: "1").sole

    assert_equal %w[dutch recipe], suggestion.terms
    assert_equal 5, suggestion.query_count
    assert_equal 5, suggestion.distinct_users
    assert_equal "dutch_recipe", suggestion.label_key
    assert_equal "Is this email about dutch and recipe?", suggestion.question
  end

  test "one user repeating a query 20 times counts as one distinct user" do
    20.times { miss("dutch recipes", user: "same") }
    3.times { |i| miss("dutch recipes", user: "u#{i}") }

    assert_empty Suggestions.for(Email, tenant_key: "1")
    assert_empty Truffler::Misses.clusters(Email, tenant_key: "1")
  end

  test "misses from tenant A never appear in suggestions for tenant B" do
    5.times { |i| miss("dutch recipes", user: "u#{i}", tenant: "A") }

    assert_empty Suggestions.for(Email, tenant_key: "B")
    assert_equal 1, Suggestions.for(Email, tenant_key: "A").size
  end

  test "queries cluster by shared non-filler terms and expose only terms seen from enough users" do
    miss("find dutch recipes", user: "u0")
    miss("show me dutch cooking", user: "u1")
    miss("dutch emails from grandma", user: "u2")
    miss("my dutch stuff", user: "u3")
    miss("dutch", user: "u4")
    miss("invoice 4471 from bob@example.com", user: "u5")

    cluster = Truffler::Misses.clusters(Email, tenant_key: "1").sole

    assert_equal %w[dutch], cluster.terms
    assert_equal 5, cluster.query_count
    assert_equal 5, cluster.distinct_users
    assert_not_includes cluster.to_h.to_s, "grandma"
  end

  test "the public clusters API accepts a record type name and never lowers the configured user gate" do
    5.times { |i| miss("dutch recipes", user: "u#{i}") }

    assert_equal 1, Truffler::Misses.clusters("Email", tenant_key: "1").size
    assert_equal 1, Truffler::Misses.clusters(Email, tenant_key: "1", min_distinct_users: 1).size
    assert_empty Truffler::Misses.clusters(Email, tenant_key: "1", min_distinct_users: 6)

    Truffler.config.miss_min_distinct_users = 6
    assert_empty Truffler::Misses.clusters(Email, tenant_key: "1", min_distinct_users: 2)
  end

  test "clusters across all tenants when asked" do
    3.times { |i| miss("dutch recipes", user: "a#{i}", tenant: "A") }
    2.times { |i| miss("dutch recipes", user: "b#{i}", tenant: "B") }

    assert_empty Truffler::Misses.clusters(Email, tenant_key: "A")
    assert_equal 5, Truffler::Misses.clusters(Email, tenant_key: Truffler::Misses::ALL_TENANTS).sole.distinct_users
  end

  test "misses older than the retention window are ignored even before pruning" do
    travel_to(31.days.ago) { 5.times { |i| miss("dutch recipes", user: "u#{i}") } }

    assert_empty Suggestions.for(Email, tenant_key: "1")
  end

  test "an encrypted model with AR encryption clusters decrypted text" do
    5.times { |i| miss("vault codes", user: "u#{i}", tenant: "3", model: SecretNote) }

    suggestion = Suggestions.for(SecretNote, tenant_key: "3").sole

    assert_equal %w[vault code], suggestion.terms
    assert_equal "Is this secret note about vault and code?", suggestion.question
  end

  test "an encrypted model without AR encryption suggests digest-only counts without text" do
    config = ActiveRecord::Encryption.config
    primary_key = config.instance_variable_get(:@primary_key)
    config.primary_key = nil
    5.times { |i| miss("vault codes", user: "u#{i}", tenant: "3", model: SecretNote) }

    suggestion = Suggestions.for(SecretNote, tenant_key: "3").sole

    assert_empty suggestion.terms
    assert_nil suggestion.question
    assert_nil suggestion.label_key
    assert_equal 5, suggestion.distinct_users
    assert_empty Truffler::Misses.clusters(SecretNote, tenant_key: "3")
  ensure
    config.primary_key = primary_key
  end

  test "the rake task prints suggestions for a model" do
    5.times { |i| miss("dutch recipes", user: "u#{i}") }
    rake = Rake::Application.new
    Rake.application = rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/truffler/suggestions.rake", __dir__)

    output = capture_io { rake["truffler:suggestions"].invoke("Email") }.first

    assert_includes output, "5 queries from 5 users: dutch, recipe"
    assert_includes output, %(label :dutch_recipe, :noul, question: "Is this email about dutch and recipe?")
  end

  test "the report says so when nothing qualifies" do
    io = StringIO.new
    Suggestions.report(Email, io: io)

    assert_includes io.string, "No query miss clusters for Email"
  end
end
