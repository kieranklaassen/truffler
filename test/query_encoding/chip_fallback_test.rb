require "test_helper"

class BillingTopicEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject
    label :billing, :noul, question: "Is this about billing?", boost: 1.0
    label :topic, :choice, question: "Which topic?", options: %w[billing travel], filter_at: 0.5
    keyword :subject
  end
end

class ChipFallbackTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Encoder = Truffler::QueryEncoding::Encoder
  Encoding = Truffler::Search::Encoding
  Query = Truffler::Search::Query

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
    @fake = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => Truffler::NO_OPTION, "token" => "keyword" }[tag] }
    Truffler.config.client = @fake
    @cache = Truffler::Search::EncodingCache.new
  end

  def encode(model, text)
    query = Query.new(text)
    key = @cache.key(model, query, tenant_key: "1", user_key: "user-1")
    Truffler::QueryEncoding::Prefetch.new.call(model, query, cache_key: key, tenant_key: "1", user_key: "user-1")
    Encoder.new.encode(key)
  end

  def label_row!(record, values)
    now = Time.current
    values.each do |key, value|
      Truffler::Records::Label.create!(record_type: record.class.polymorphic_name, record_id: record.id, tenant_key: "1",
        label_key: key.to_s, value: value, fingerprint: "fp", labeled_at: now)
    end
    record
  end

  test "0.1.4: removing the urgent chip makes 'urgent' a keyword again, and the text match ranks" do
    @fake.answer("intent__urgent", "filter")
    both = inbox_email!(subject: "Urgent refunds pending", labels: { urgent: 0.9 })
    refunds = inbox_email!(subject: "Refunds batch", labels: { urgent: 0.9 })
    inbox_email!(subject: "Refunds report", labels: { urgent: 0.1 })

    encoding = encode(InboxEmail, "urgent refunds")
    filtered = search(InboxEmail, "urgent refunds")
    removed = search(InboxEmail, "urgent refunds", suppressed: [ "urgent" ])

    assert_equal({ "urgent" => %w[urgent] }, encoding.label_term_sources)
    assert_equal %w[refunds], encoding.keyword_tokens
    assert_equal [ refunds.id, both.id ], filtered.records.map(&:id)
    assert_equal [ both.id ], removed.records.map(&:id)
    assert_empty removed.chips
    assert_equal %w[refunds urgent], encoding.without([ "urgent" ]).keywords(Query.new("urgent refunds")).sort
  end

  test "0.1.4: a token naming two applied labels stays a label term until both chips are removed" do
    @fake.answer("intent__billing", "boost").answer("intent__topic", "filter").answer("option__topic", "billing")

    encoding = encode(BillingTopicEmail, "billing refunds")
    query = Query.new("billing refunds")

    assert_equal({ "billing" => %w[billing topic:billing] }, encoding.label_term_sources)
    assert_equal %w[refunds], encoding.without([ "billing" ]).keywords(query)
    assert_equal %w[refunds], encoding.without([ "topic" ]).keywords(query)
    assert_equal %w[refunds billing], encoding.without(%w[billing topic]).keywords(query)
    assert_empty encoding.without(%w[billing topic]).label_term_tokens
  end

  test "0.1.4: label-term sources survive the cache without query text" do
    query = Query.new("Urgent billing refunds")
    encoding = Encoding.new(filters: { urgent: 0.6 }, keyword_tokens: %w[refunds], label_term_tokens: %w[urgent billing],
      label_term_sources: { "urgent" => %w[urgent], "billing" => %w[urgent category:billing] }, soft_keyword_tokens: %w[billing])

    dumped = encoding.dump(query)

    assert_equal [ [ 0, %w[urgent] ], [ 1, %w[urgent category:billing] ] ], dumped["label_term_sources"]
    assert_equal [ 1 ], dumped["soft_keyword_positions"]
    %w[urgent billing refunds].each { |word| assert_not_includes Truffler::Canonical.json(dumped.except("filters", "label_term_sources")), word }
    assert_equal encoding, Encoding.load(dumped, query)
    assert_equal({}, Encoding.load(dumped.except("label_term_sources", "soft_keyword_positions"), query).label_term_sources)
  end

  test "0.1.4: a word naming a label key only by prefix adds a soft keyword score without being required" do
    @fake.answer("intent__urgent", "filter")
    text = inbox_email!(subject: "Please reply urgently", labels: { urgent: 0.9 })
    other = inbox_email!(subject: "Server down", labels: { urgent: 0.9 })

    encoding = encode(InboxEmail, "urgently")
    result = search(InboxEmail, "urgently")

    assert_equal %w[urgently], encoding.label_term_tokens
    assert_equal %w[urgently], encoding.soft_keyword_tokens
    assert_empty encoding.keyword_tokens
    assert_equal [ text.id, other.id ], result.records.map(&:id)
    assert_operator result.breakdown(text)[:keyword], :>, 0
    assert_equal 0.0, result.breakdown(other)[:keyword]
  end

  test "0.1.4: a word Jev calls a label term that names no applied label locally is sourced to every applied label" do
    @fake.answer("intent__urgent", "filter").answer("intent__needs_action", "boost").answer("token__0", "label_term")

    encoding = encode(InboxEmail, "asap refunds")

    assert_equal({ "asap" => %w[needs_action urgent] }, encoding.label_term_sources)
    assert_equal %w[refunds], encoding.without([ "urgent" ]).keyword_tokens
    assert_equal %w[refunds asap], encoding.without(%w[urgent needs_action]).keyword_tokens
  end

  test "0.1.4: an exact label-key match is not soft" do
    @fake.answer("intent__urgent", "filter")

    assert_empty encode(InboxEmail, "urgent").soft_keyword_tokens
  end
end
