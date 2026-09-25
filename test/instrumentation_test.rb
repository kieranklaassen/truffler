require "test_helper"

class InstrumentationTest < Truffler::TestCase
  QUESTIONS = Truffler::Test::ClientContract::QUESTIONS
  STATE = Truffler::Test::ClientContract::STATE

  test "a jev_call payload has tokens, cost, model, and latency but no state" do
    host = Truffler::Test::HostClient.new(response: Truffler::Test::ClientContract::RESPONSE)

    payload = capture_notifications("truffler.jev_call") do
      Truffler::Clients::Callable.new(host).ask(state: STATE, questions: QUESTIONS, priority: :backfill)
    end.sole

    assert_equal 120, payload[:input_tokens]
    assert_equal false, payload[:tokens_estimated]
    assert_in_delta 120 * 0.042 / 1_000_000, payload[:cost]
    assert_equal "jev-1.13", payload[:model]
    assert_kind_of Numeric, payload[:latency_ms]
    assert_equal :backfill, payload[:priority]
    assert_not payload.key?(:state)
    assert_not payload.key?(:questions)
  end

  test "a failed call reports the error class and status without the body" do
    host = Truffler::Test::HostClient.new(error: Truffler::Test::HttpError.new(500, "Buy cheap watches now"))

    payload = capture_notifications("truffler.jev_call") do
      assert_raises(Truffler::ClientError) do
        Truffler::Clients::Callable.new(host).ask(state: STATE, questions: QUESTIONS)
      end
    end.sole

    assert_equal "Truffler::Test::HttpError", payload[:error_class]
    assert_equal 500, payload[:status]
    assert_not_includes payload.to_s, "watches"
  end

  test "Redaction keeps only allowlisted keys" do
    safe = Truffler::Redaction.safe(
      record_type: "Email", record_ids: [ 1, 2 ], tenant_key: "7", input_tokens: 10, query_digest: "abc",
      query: "secret words", state: { body: "secret" }, message: "secret", latency_ms: 3.2
    )

    assert_equal %i[input_tokens latency_ms query_digest record_ids record_type tenant_key], safe.keys.sort
  end
end
