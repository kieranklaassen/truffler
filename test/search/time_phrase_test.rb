require "test_helper"

class SearchTimePhraseTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers
  include ActiveSupport::Testing::TimeHelpers

  Query = Truffler::Search::Query
  # A Wednesday afternoon.
  NOW = Time.utc(2026, 9, 23, 15, 30)

  def window(text)
    phrase = Query.new(text).time_phrase
    phrase && [ phrase.name, *phrase.window(NOW) ]
  end

  test "0.1.1: parses day, week, month, rolling, and since-weekday phrases against the clock" do
    assert_equal [ "Today", Time.utc(2026, 9, 23), nil ], window("invoices today")
    assert_equal [ "Yesterday", Time.utc(2026, 9, 22), Time.utc(2026, 9, 23) ], window("yesterday refunds")
    assert_equal [ "This week", Time.utc(2026, 9, 21), nil ], window("angry customers this week")
    assert_equal [ "Last week", Time.utc(2026, 9, 14), Time.utc(2026, 9, 21) ], window("last week")
    assert_equal [ "This month", Time.utc(2026, 9, 1), nil ], window("this month")
    assert_equal [ "Last month", Time.utc(2026, 8, 1), Time.utc(2026, 9, 1) ], window("last month churn")
    assert_equal [ "Last 7 days", NOW - 7.days, nil ], window("bugs in the past 7 days")
    assert_equal [ "Last 1 day", NOW - 1.day, nil ], window("last 1 day")
    assert_equal [ "Last 2 weeks", NOW - 14.days, nil ], window("last 2 weeks")
    assert_equal [ "Since Monday", Time.utc(2026, 9, 21), nil ], window("since monday")
    assert_equal [ "Since Wednesday", Time.utc(2026, 9, 23), nil ], window("since wednesday")
    assert_equal [ "Since Thursday", Time.utc(2026, 9, 17), nil ], window("since thursday")
    assert_nil window("weekly report")
    assert_nil window(%("this week" newsletter))
  end

  test "0.1.1: time words leave the keywords, the exact tokens, and the Jev questions" do
    query = Query.new("refunds past 30 days")
    assert_equal %w[refunds], query.search_tokens
    assert_empty query.exact_tokens

    request = Truffler::QueryEncoding::Encoder.new.request(InboxEmail, Query.new("angry customers this week"), tenant_key: "1")
    assert_equal %w[token__0 token__1], request.questions.keys.grep(/\Atoken__/)
  end

  test "0.1.1: angry customers this week matches this week's records only, with a removable time chip" do
    fresh = inbox_email!(subject: "Angry customers on the forum")
    fresh.update_columns(created_at: NOW - 1.day)
    stale = inbox_email!(subject: "Angry customers again")
    stale.update_columns(created_at: NOW - 8.days)
    travel_to(NOW)

    result = search(InboxEmail, "angry customers this week")
    widened = search(InboxEmail, "angry customers this week", suppressed: [ "time" ])

    assert_equal [ fresh.id ], result.records.map(&:id)
    assert_equal [ { key: "time", label: "time", kind: :time, name: "This week" } ], result.chips
    assert_equal [ fresh.id, stale.id ].sort, widened.records.map(&:id).sort
    assert_empty widened.chips
    assert_equal 0, InboxEmail.jev_new_matches_count("angry customers this week", tenant: 1, scope: InboxEmail.all,
      user: "user-1", since: NOW)
  end

  test "0.1.1: the time range combines with a cached label encoding" do
    fresh = inbox_email!(subject: "Pay the plumber", labels: { needs_action: 0.9 })
    fresh.update_columns(created_at: NOW - 1.hour)
    inbox_email!(subject: "Pay the roofer", labels: { needs_action: 0.9 }).update_columns(created_at: NOW - 2.days)
    cache_encoding!(InboxEmail, "needs action today", filters: { needs_action: 0.6 }, keyword_tokens: [],
      label_term_tokens: %w[needs action])

    result = search(InboxEmail, "needs action today", clock: -> { NOW })

    assert_equal [ fresh.id ], result.records.map(&:id)
    assert_equal %i[filter time], result.chips.map { |chip| chip[:kind] }
  end
end
