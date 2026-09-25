require "test_helper"

class PruneQueryMissesJobTest < Truffler::TestCase
  QueryMiss = Truffler::Records::QueryMiss

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
  end

  def miss_at(time, query)
    travel_to(time) { Truffler::Misses.record(Email, tenant_key: "1", user_key: "u", query: query) }
  end

  test "deletes a 31-day-old miss and keeps a 29-day-old one" do
    miss_at(31.days.ago, "old query")
    miss_at(29.days.ago, "recent query")

    Truffler::Jobs::PruneQueryMissesJob.perform_now

    assert_equal [ "recent query" ], QueryMiss.pluck(:query_text)
  end

  test "honors a configured retention window and instruments the deleted count" do
    Truffler.config.miss_retention = 7.days
    miss_at(8.days.ago, "old query")
    miss_at(6.days.ago, "recent query")

    payloads = capture_notifications("truffler.miss_prune") { Truffler::Jobs::PruneQueryMissesJob.perform_now }

    assert_equal [ "recent query" ], QueryMiss.pluck(:query_text)
    assert_equal 1, payloads.sole[:deleted_count]
  end

  test "defaults to a 30 day retention and a gate of 5 distinct users" do
    assert_equal 30.days, Truffler.config.miss_retention
    assert_equal 5, Truffler.config.miss_min_distinct_users
  end
end
