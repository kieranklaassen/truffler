require "test_helper"

class EncodeQueryJobTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
    @fake = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => "none", "token" => "filler" }[tag] }
      .answer("intent__needs_action", "filter").answer("token__2", "label_term").answer("token__4", "label_term")
    Truffler.config.client = @fake
  end

  test "covers AE1 end to end: the first keystroke enqueues, and the next applies the cached filter with no Jev call" do
    now = Time.current
    older = inbox_email!(subject: "Pay the plumber", received_at: now - 2.hours, labels: { needs_action: 0.95 })
    newer = inbox_email!(subject: "Sign the lease", received_at: now - 1.hour, labels: { needs_action: 0.7 })
    inbox_email!(subject: "Newsletter", received_at: now, labels: { needs_action: 0.2 })
    query = "emails I need to act on right now"

    assert_equal :pending, search(InboxEmail, query).encoding_status
    perform_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)
    assert_equal 1, @fake.calls.size

    calls = capture_notifications("truffler.jev_call") { @result = search(InboxEmail, query) }

    assert_empty calls
    assert_no_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)
    assert_equal :cached, @result.encoding_status
    assert_equal [ newer.id, older.id ], @result.records.map(&:id)
    assert_equal [ { key: "needs_action", label: "needs_action", kind: :filter, name: "Needs action" } ], @result.chips
    assert_equal %w[need act], @result.encoding.label_term_tokens
  end

  test "covers AE10: a first-time query shows the Smart search row and keeps its list; the next keystroke applies the filter" do
    act = Email.create!(account_id: 1, subject: "Sign the lease")
    label!(act, needs_action: 0.9)
    label!(Email.create!(account_id: 1, subject: "Newsletter"), needs_action: 0.1)
    query = "emails I need to act on right now"

    first = search(Email, query)
    before = first.records.map(&:id)
    perform_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)

    assert_equal({ query: query, reason: :encoding_pending }, first.invite_row)
    assert_equal :pending, first.encoding_status
    assert_equal before, first.records.map(&:id)
    assert_nil first.encoding

    second = search(Email, query)
    assert_equal :cached, second.encoding_status
    assert_equal [ act.id ], second.records.map(&:id)
    assert_equal({ "needs_action" => 0.6 }, second.encoding.filters)
    assert_not_equal :encoding_pending, second.invite_row&.dig(:reason)
  end

  test "a Jev failure is discarded, releases the in-flight marker, and the search still returns" do
    @fake.fail_with(Truffler::ClientError.new(status: 503))
    inbox_email!(subject: "Invoice")

    search(InboxEmail, "invoice")
    perform_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)

    key = Truffler::Search::EncodingCache.new.key(InboxEmail, Truffler::Search::Query.new("invoice"), tenant_key: "1")
    assert_not Truffler::QueryEncoding::Cache.new.in_flight?(key)
    assert_equal 1, search(InboxEmail, "invoice").records.size
    assert_enqueued_jobs 1, only: Truffler::Jobs::EncodeQueryJob
  end

  test "an expired payload is a no-op" do
    assert_nil Truffler::Jobs::EncodeQueryJob.perform_now("truffler/enc/#{'0' * 64}")
    assert_empty @fake.calls
  end
end
