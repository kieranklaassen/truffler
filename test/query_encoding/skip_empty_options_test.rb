require "test_helper"

class SkipEmptyOptionsTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Encoder = Truffler::QueryEncoding::Encoder
  Query = Truffler::Search::Query

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
    Truffler.config.encoding_prefetch = nil
    @fake = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => Truffler::NO_OPTION, "token" => "keyword" }[tag] }
    Truffler.config.client = @fake
    @cache = Truffler::Search::EncodingCache.new
  end

  def request(query = "billing refunds")
    Encoder.new.request(InboxEmail, Query.new(query), tenant_key: "1", user_key: "user-1")
  end

  def option_criteria(request)
    request.questions.dig("option__category", "criteria")&.keys
  end

  def encode(text)
    query = Query.new(text)
    key = @cache.key(InboxEmail, query, tenant_key: "1", user_key: "user-1")
    Truffler::QueryEncoding::Prefetch.new.call(InboxEmail, query, cache_key: key, tenant_key: "1", user_key: "user-1")
    Encoder.new.encode(key)
  end

  def selects_during
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  test "0.1.6: skip_empty_options defaults to false and every option is asked" do
    inbox_email!(labels: { "category:billing" => 0.9 })

    assert_equal false, Truffler.config.skip_empty_options
    assert_equal [ "billing", "travel", "other", Truffler::NO_OPTION ], option_criteria(request)
  end

  test "0.1.6: with skip_empty_options, options with no label row at or above choice_min_probability are not offered" do
    Truffler.config.skip_empty_options = true
    inbox_email!(labels: { "category:billing" => 0.9, "category:travel" => 0.01 })
    inbox_email!(account_id: 2, labels: { "category:other" => 0.9 })

    built = request

    assert_equal [ "billing", Truffler::NO_OPTION ], option_criteria(built)
    assert_equal [ "billing" ], built.state.dig("labels", "category", "options")
  end

  test "0.1.6: a choice label with no present option is left out of the encoding request" do
    Truffler.config.skip_empty_options = true
    inbox_email!(labels: { urgent: 0.9 })

    built = request

    assert_not built.questions.key?("intent__category")
    assert_not built.questions.key?("option__category")
    assert built.questions.key?("intent__urgent")
  end

  test "0.1.6: an option Jev picks that the tenant does not have applies nothing" do
    Truffler.config.skip_empty_options = true
    inbox_email!(labels: { "category:billing" => 0.9 })
    @fake.answer("intent__category", "filter").answer("option__category", "travel")

    assert_empty encode("travel refunds").filters
  end

  test "0.1.6: the present-option set is in the encoding cache key and refreshes within its TTL" do
    Truffler.config.skip_empty_options = true
    inbox_email!(labels: { "category:billing" => 0.9 })
    query = Query.new("travel refunds")
    before = @cache.key(InboxEmail, query, tenant_key: "1", user_key: "user-1")
    Truffler.config.skip_empty_options = false
    disabled = @cache.key(InboxEmail, query, tenant_key: "1", user_key: "user-1")
    Truffler.config.skip_empty_options = true

    inbox_email!(labels: { "category:travel" => 0.9 })
    stale = @cache.key(InboxEmail, query, tenant_key: "1", user_key: "user-1")
    travel(Truffler::QueryEncoding::PresentOptions::TTL + 1.second) do
      @after = @cache.key(InboxEmail, query, tenant_key: "1", user_key: "user-1")
      assert_equal [ "billing", "travel", Truffler::NO_OPTION ], option_criteria(request)
    end

    assert_not_equal disabled, before
    assert_equal before, stale
    assert_not_equal before, @after
  end

  test "0.1.6: with a warm present-option cache the keystroke stays one SELECT" do
    Truffler.config.skip_empty_options = true
    inbox_email!(subject: "Invoice", labels: { "category:billing" => 0.9 })
    search(InboxEmail, "invoice")

    statements = selects_during { @result = search(InboxEmail, "invoice") }

    assert_equal 1, statements.size, statements.join("\n")
    assert_equal 1, @result.records.size
  end
end
