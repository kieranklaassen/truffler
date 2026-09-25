require "test_helper"

class RecorderTest < Truffler::TestCase
  QueryMiss = Truffler::Records::QueryMiss

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
  end

  test "the hook is a callable that records one miss with digests and the tenant" do
    hook = Truffler::Misses.hook
    assert_respond_to hook, :call

    hook.call(Email, tenant_key: "1", user_key: "user-7", query: "  Dutch   Recipes ")

    miss = QueryMiss.sole
    assert_equal "Email", miss.record_type
    assert_equal "1", miss.tenant_key
    assert_equal "dutch recipes", miss.query_text
    assert_equal "dutch recipes", miss.query
    assert_match(/\A\h{64}\z/, miss.query_digest)
    assert_match(/\A\h{64}\z/, miss.user_digest)
    assert_not_includes miss.user_digest, "user-7"
  end

  test "digests are keyed, stable across casing and spacing, and differ per user" do
    Truffler::Misses.record(Email, tenant_key: "1", user_key: "a", query: "Dutch recipes")
    Truffler::Misses.record(Email, tenant_key: "1", user_key: "a", query: "dutch  RECIPES")
    Truffler::Misses.record(Email, tenant_key: "1", user_key: "b", query: "dutch recipes")

    assert_equal 1, QueryMiss.distinct.count(:query_digest)
    assert_equal 2, QueryMiss.distinct.count(:user_digest)
    assert_not_equal Digest::SHA256.hexdigest("dutch recipes"), QueryMiss.first.query_digest

    Truffler.config.secret_key_base = "another-secret"
    Truffler::Misses.record(Email, tenant_key: "1", user_key: "a", query: "dutch recipes")
    assert_equal 2, QueryMiss.distinct.count(:query_digest)
  end

  test "a blank query or an undeclared model records nothing" do
    Truffler::Misses.record(Email, tenant_key: "1", user_key: "a", query: "   ")
    Truffler::Misses.record(String, tenant_key: "1", user_key: "a", query: "anything")

    assert_equal 0, QueryMiss.count
  end

  test "a miss without a user key is stored without a user digest" do
    Truffler::Misses.record(Email, tenant_key: "1", user_key: nil, query: "dutch recipes")

    assert_nil QueryMiss.sole.user_digest
  end

  test "on an encrypted model with AR encryption configured the stored text is ciphertext" do
    Truffler::Misses.record(SecretNote, tenant_key: "3", user_key: "a", query: "Swordfish vault")

    raw = QueryMiss.connection.select_value("SELECT query_text FROM truffler_query_misses")
    assert_not_nil raw
    assert_not_includes raw, "swordfish"
    assert_equal "swordfish vault", QueryMiss.sole.query
  end

  test "on an encrypted model without AR encryption configured only the digest is stored" do
    config = ActiveRecord::Encryption.config
    primary_key = config.instance_variable_get(:@primary_key)
    config.primary_key = nil

    Truffler::Misses.record(SecretNote, tenant_key: "3", user_key: "a", query: "swordfish vault")

    miss = QueryMiss.sole
    assert_nil miss.query_text
    assert_nil miss.query
    assert_match(/\A\h{64}\z/, miss.query_digest)
  ensure
    config.primary_key = primary_key
  end

  test "a recording failure is instrumented by class and never raises into the caller" do
    Truffler.config.secret_key_base = nil

    payloads = capture_notifications("truffler.miss") do
      assert_nil Truffler::Misses.record(Email, tenant_key: "1", user_key: "a", query: "dutch recipes")
    end

    assert_equal 0, QueryMiss.count
    assert_equal "Truffler::Error", payloads.sole[:error_class]
    assert_not_includes payloads.to_s, "dutch"
  end

  test "a recorded miss is instrumented without query or user text" do
    payloads = capture_notifications("truffler.miss") do
      Truffler::Misses.record(Email, tenant_key: "1", user_key: "user-7", query: "dutch recipes")
    end

    assert_equal "recorded", payloads.sole[:outcome]
    assert_not_includes payloads.to_s, "dutch"
    assert_not_includes payloads.to_s, "user-7"
  end
end
