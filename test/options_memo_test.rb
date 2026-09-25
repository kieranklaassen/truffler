require "test_helper"

module CountedOptions
  CALLS = Hash.new(0)

  def self.for(tenant_key)
    CALLS[tenant_key.to_s] += 1
    { "cora" => "Cora", "jev" => { description: "Jev", search: "jev api" } }
  end
end

class CountedOptionEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject
    label :product, :choice, question: "Which product is this about?", options: ->(tenant_key) { CountedOptions.for(tenant_key) },
      filter_at: 0.5
    label :urgent, :noul, question: "Is this urgent?"
    keyword :subject
  end
end

class OptionsMemoTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
    Truffler.config.encoding_prefetch = nil
    CountedOptions::CALLS.clear
  end

  def calls_during
    CountedOptions::CALLS.clear
    yield
    CountedOptions::CALLS.dup
  end

  test "0.1.6: a keystroke search resolves a per-tenant options callable once per tenant, and the next search again" do
    CountedOptionEmail.create!(account_id: 1, subject: "Cora invoice")
    cache_encoding!(CountedOptionEmail, "cora invoice", filters: { "product:cora" => 0.5 }, keyword_tokens: %w[invoice])

    assert_equal({ "1" => 1 }, calls_during { search(CountedOptionEmail, "cora invoice") })
    assert_equal({ "1" => 1 }, calls_during { search(CountedOptionEmail, "cora invoice") })
    assert_equal({ "2" => 1 }, calls_during { search(CountedOptionEmail, "cora invoice", tenant: 2) })
  end

  test "0.1.6: one query encoding resolves the options callable once" do
    Truffler.config.client = Truffler::Clients::Fake.new
    query = Truffler::Search::Query.new("cora invoice")
    cache = Truffler::Search::EncodingCache.new
    key = cache.key(CountedOptionEmail, query, tenant_key: "1", user_key: "user-1")
    Truffler::QueryEncoding::Prefetch.new.call(CountedOptionEmail, query, cache_key: key, tenant_key: "1", user_key: "user-1")

    assert_equal({ "1" => 1 }, calls_during { Truffler::QueryEncoding::Encoder.new.encode(key) })
  end

  test "0.1.6: one labeler batch resolves the options callable once per tenant" do
    Truffler.config.client = Truffler::Clients::Fake.new.answer(:product, "cora")
    3.times { CountedOptionEmail.create!(account_id: 1, subject: "Cora") }
    clear_enqueued_jobs
    states = Truffler::Records::RecordState.for_model(CountedOptionEmail).to_a

    assert_equal({ "1" => 1 }, calls_during { Truffler::Labeling::Labeler.new(CountedOptionEmail).label(states, priority: :live) })
    assert_equal 3, Truffler::Records::Label.where(label_key: "product:cora", value: 1.0..).count
  end

  test "0.1.6: one Smart search planning step resolves the options callable once" do
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new
    CountedOptionEmail.create!(account_id: 1, subject: "Cora invoice")
    cache_encoding!(CountedOptionEmail, "cora invoice", filters: { "product:cora" => 0.5 }, keyword_tokens: %w[invoice])
    clear_enqueued_jobs
    run = CountedOptionEmail.jev_smart_search("cora invoice", tenant: 1, scope: CountedOptionEmail.all, user: "user-1")

    assert_equal({ "1" => 1 }, calls_during { Truffler::SmartSearch::Dispatcher.new(enqueue: ->(*) { }).call(run) })
  end

  test "0.1.6: outside a search the callable is not memoized" do
    label = CountedOptionEmail.truffler_definition.label(:product)

    assert_equal({ "1" => 2 }, calls_during { 2.times { label.options("1") } })
    assert_equal({ "1" => 1 }, calls_during { Truffler::Current.scope { 2.times { label.options("1") } } })
  end
end
