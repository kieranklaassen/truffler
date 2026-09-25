require "test_helper"

# A label key word ("customer") and an option search text ("text message")
# that overlap the default filler words.
class ChannelEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject
    label :customer_reply, :noul, question: "Is this a reply from a customer?"
    label :channel, :choice, question: "Which channel did this arrive on?",
      options: { "sms" => { description: "Arrived as an SMS", search: "text message" }, "web" => "Arrived through the web form" }
    keyword :subject
  end
end

class SearchFillerTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers
  include ActiveSupport::Testing::TimeHelpers

  Encoder = Truffler::QueryEncoding::Encoder
  Query = Truffler::Search::Query
  # A Wednesday afternoon.
  NOW = Time.utc(2026, 9, 23, 15, 30)

  setup do
    Truffler.config.secret_key_base = "test-secret-key-base"
    @fake = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => Truffler::NO_OPTION, "token" => "keyword" }[tag] }
    Truffler.config.client = @fake
    travel_to(NOW)
  end

  def email_at(subject, at)
    inbox_email!(subject: subject).tap { |email| email.update_columns(created_at: at) }
  end

  def encode(query)
    query = Query.new(query)
    key = Truffler::Search::EncodingCache.new.key(InboxEmail, query, tenant_key: "1")
    Truffler::QueryEncoding::Prefetch.new.call(InboxEmail, query, cache_key: key, tenant_key: "1", user_key: "user-1")
    Encoder.new.encode(key)
  end

  test "0.1.4: cold cache: customers in the last 3 hours returns the in-window record" do
    fresh = email_at("Refund please", NOW - 1.hour)
    email_at("Refund please", NOW - 5.hours)

    result = search(InboxEmail, "customers in the last 3 hours")

    assert_equal :pending, result.encoding_status
    assert_equal [ fresh.id ], result.records.map(&:id)
    assert_equal [ fresh.id ], search(InboxEmail, "in the last 3 hours").records.map(&:id)
  end

  test "0.1.4: cached encoding: customers in the last 3 hours returns the in-window record" do
    fresh = email_at("Refund please", NOW - 1.hour)
    email_at("Refund please", NOW - 5.hours)

    encoding = encode("customers in the last 3 hours")
    result = search(InboxEmail, "customers in the last 3 hours")

    assert_empty encoding.keyword_tokens
    assert_equal :cached, result.encoding_status
    assert_equal [ fresh.id ], result.records.map(&:id)
  end

  test "0.1.4: customers refund this week requires only refund, cached or cold" do
    refund = email_at("Refund issued", NOW - 1.day)
    email_at("Happy customers", NOW - 1.day)

    cold = search(InboxEmail, "customers refund this week")
    encoding = encode("customers refund this week")
    cached = search(InboxEmail, "customers refund this week")

    assert_equal [ refund.id ], cold.records.map(&:id)
    assert_equal %w[refund], encoding.keyword_tokens
    assert_equal [ refund.id ], cached.records.map(&:id)
  end

  test "0.1.4: a lone filler word stays a keyword, cached or cold" do
    customers = email_at("Customers asked again", NOW - 1.day)
    email_at("Refund issued", NOW - 1.day)

    assert_equal [ customers.id ], search(InboxEmail, "customers").records.map(&:id)
    assert_equal %w[customers], encode("customers").keyword_tokens
    assert_equal [ customers.id ], search(InboxEmail, "customers").records.map(&:id)
    assert_equal %w[customers], encode("the customers").keyword_tokens
    assert_equal %w[the], encode("the").keyword_tokens
  end

  test "0.1.4: a filler word beside an applied label is dropped" do
    @fake.answer("intent__urgent", "filter")

    encoding = encode("urgent messages")

    assert_equal %w[urgent], encoding.label_term_tokens
    assert_empty encoding.keyword_tokens
  end

  test "0.1.4: config.filler_words can be replaced or extended, singular or plural" do
    assert_includes Truffler.config.filler_words, "customers"
    Truffler.config.filler_words = %w[ticket]

    assert_equal %w[customers refund], encode("customers refund tickets").keyword_tokens
    assert_equal %w[customers refund], Truffler::Search::Encoding.new.keywords(Query.new("customers refund tickets"))

    Truffler.config.filler_words += %w[customer]
    assert_equal %w[refund], Truffler::Search::Encoding.new.keywords(Query.new("customers refund ticket"))
  end

  test "0.1.4: removing the time chip brings a dropped filler noun back, cached or cold" do
    customers = email_at("Customers asked again", NOW - 30.days)
    email_at("Refund issued", NOW - 30.days)

    encoding = encode("customers in the last 3 hours")
    assert_empty encoding.keyword_tokens
    assert_includes encoding.filler_tokens, "customers"
    assert_equal %w[customers], encoding.without([ "time" ]).keyword_tokens

    cached = search(InboxEmail, "customers in the last 3 hours", suppressed: [ "time" ])
    assert_equal [ customers.id ], cached.records.map(&:id)
    Truffler.config.cache_store.clear
    cold = search(InboxEmail, "customers in the last 3 hours", suppressed: [ "time" ])
    assert_equal [ customers.id ], cold.records.map(&:id)
  end

  test "0.1.4: removing the last label chip frees its word; filler stays dropped while a real keyword remains" do
    @fake.answer("intent__urgent", "filter")

    encoding = encode("urgent messages")

    assert_equal %w[urgent], encoding.without([ "urgent" ]).keyword_tokens
  end

  CHANNEL_EMAIL = ChannelEmail

  def encode_for(model, query)
    query = Query.new(query)
    key = Truffler::Search::EncodingCache.new.key(model, query, tenant_key: "1")
    Truffler::QueryEncoding::Prefetch.new.call(model, query, cache_key: key, tenant_key: "1", user_key: "user-1")
    Encoder.new.encode(key)
  end

  test "0.1.5: a word naming a declared label key or option search text is never filler, applied or not, cached or cold" do
    texts = CHANNEL_EMAIL.create!(account_id: 1, subject: "Text messages about a refund")
    CHANNEL_EMAIL.create!(account_id: 1, subject: "Refund issued")
    customers = CHANNEL_EMAIL.create!(account_id: 1, subject: "Customers want a refund")

    assert_equal [ texts.id ], search(CHANNEL_EMAIL, "messages refund").records.map(&:id)
    assert_equal [ customers.id ], search(CHANNEL_EMAIL, "customers refund").records.map(&:id)
    assert_equal %w[messages refund], encode_for(CHANNEL_EMAIL, "messages refund").keyword_tokens
    assert_equal [ texts.id ], search(CHANNEL_EMAIL, "messages refund").records.map(&:id)
    assert_equal %w[customers refund], encode_for(CHANNEL_EMAIL, "customers refund").keyword_tokens
  end

  test "0.1.5: a label vocabulary word Jev calls filler stays a keyword" do
    @fake.answer("token__0", "filler")

    assert_equal %w[messages refund], encode_for(CHANNEL_EMAIL, "messages refund").keyword_tokens
    assert_equal %w[refund], encode_for(CHANNEL_EMAIL, "stuff refund").keyword_tokens
  end

  test "0.1.5: email and emails are no longer default filler words" do
    assert_not_includes Truffler.config.filler_words, "email"
    assert_not_includes Truffler.config.filler_words, "emails"
    assert_equal %w[emails refund], Truffler::Search::Encoding.new.keywords(Query.new("emails refund"))
  end

  test "0.1.5: removing the last label chip keeps filler dropped while the time chip remains" do
    @fake.answer("intent__urgent", "filter")
    labeled = email_at("Refund issued", NOW - 1.day).tap { |email| label!(email, urgent: 0.9) }
    this_week = email_at("Lunch plans", NOW - 1.day)
    old = email_at("Messages piling up", NOW - 30.days)

    encoding = encode("messages this week")
    assert_empty encoding.keyword_tokens
    assert_equal %w[messages], encoding.filler_tokens
    assert_equal [ labeled.id ], search(InboxEmail, "messages this week").records.map(&:id)

    unchipped = search(InboxEmail, "messages this week", suppressed: [ "urgent" ])
    assert_equal [ labeled.id, this_week.id ].sort, unchipped.records.map(&:id).sort
    assert_equal :time, unchipped.chips.sole[:kind]

    both = search(InboxEmail, "messages this week", suppressed: %w[urgent time])
    assert_equal [ old.id ], both.records.map(&:id)
  end

  test "0.1.5: removing a label chip frees its word, and filler stays dropped beside it, with or without time" do
    @fake.answer("intent__urgent", "filter")
    this_week = email_at("Urgent refund", NOW - 1.day)
    old = email_at("Urgent refund", NOW - 30.days)

    encode("urgent messages this week")

    assert_equal [ this_week.id ], search(InboxEmail, "urgent messages this week", suppressed: [ "urgent" ]).records.map(&:id)
    assert_equal [ this_week.id, old.id ].sort,
      search(InboxEmail, "urgent messages this week", suppressed: %w[urgent time]).records.map(&:id).sort
  end
end
