require "test_helper"

class SearchEncodingTest < Truffler::TestCase
  Encoding = Truffler::Search::Encoding
  EncodingCache = Truffler::Search::EncodingCache
  Query = Truffler::Search::Query

  test "the intent vector defaults to the boosts and drops zero weights" do
    encoding = Encoding.new(filters: { needs_action: 0.6 }, boosts: { urgent: 2.0, importance: 0 })

    assert_equal({ "needs_action" => 0.6 }, encoding.filters)
    assert_equal({ "urgent" => 2.0 }, encoding.intent_vector)
    assert_not encoding.empty?
    assert Encoding.new.empty?
  end

  test "an explicit intent vector wins over the boosts" do
    encoding = Encoding.new(filters: { needs_action: 0.6 }, intent_vector: { needs_action: 2.0, "category:billing" => 1.5 })

    assert_equal({ "needs_action" => 2.0, "category:billing" => 1.5 }, encoding.intent_vector)
  end

  test "suppressing a label removes its filter, boost, and intent weight, by label or storage key" do
    encoding = Encoding.new(filters: { needs_action: 0.6, "category:billing" => 0.5 }, boosts: { urgent: 2.0 },
      intent_vector: { needs_action: 2.0, urgent: 2.0, "category:billing" => 1.0 })

    narrowed = encoding.without(%w[needs_action category])

    assert_equal({}, narrowed.filters)
    assert_equal({ "urgent" => 2.0 }, narrowed.intent_vector)
    assert_equal({ "urgent" => 2.0 }, encoding.without([ "category:billing", :needs_action ]).boosts)
  end

  test "keywords default to the query tokens that are not label terms" do
    query = Query.new("emails I need to act on")

    assert_equal %w[emails], Encoding.new(label_term_tokens: %w[need act]).keywords(query)
    assert_equal %w[i to on], Encoding.new(label_term_tokens: %w[need act emails]).keywords(Query.new("emails I need to act on"))
    assert_equal %w[emails], Encoding.new(keyword_tokens: %w[emails]).keywords(query)
  end

  test "the cached form holds decisions and token positions, never query text" do
    query = Query.new("Invoices I must settle")
    encoding = Encoding.new(filters: { needs_action: 0.6 }, keyword_tokens: %w[invoices], label_term_tokens: %w[must settle])

    dumped = encoding.dump(query)

    assert_equal [ 0 ], dumped["keyword_positions"]
    assert_equal [ 2, 3 ], dumped["label_term_positions"]
    %w[invoices must settle].each { |word| assert_not_includes Truffler::Canonical.json(dumped), word }
    assert_equal encoding, Encoding.load(dumped, query)
  end

  test "the cache keys on the normalized query and vocabulary version" do
    cache = EncodingCache.new

    assert_equal cache.key(InboxEmail, Query.new("Needs  ACTION"), tenant_key: "1"),
      cache.key(InboxEmail, Query.new("needs action"), tenant_key: "1")
    assert_equal cache.key(InboxEmail, Query.new("needs action"), tenant_key: "1"),
      cache.key(InboxEmail, Query.new("needs action"), tenant_key: "2")
    assert_match %r{\Atruffler/enc/\h{64}\z}, cache.key(InboxEmail, Query.new("x"), tenant_key: "1")
    assert_match %r{\Atruffler/vec/\h{64}\z}, cache.vector_key(InboxEmail, Query.new("x"), tenant_key: "1")
  end

  test "a vocabulary change misses the cache" do
    cache = EncodingCache.new
    before = cache.key(InboxEmail, Query.new("needs action"), tenant_key: "1")
    Truffler.config.model = "jev-1.13"

    assert_not_equal before, cache.key(InboxEmail, Query.new("needs action"), tenant_key: "1")
  end

  test "per-tenant vocabularies key on the tenant" do
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "emails"
      def self.name = "TenantFolderEmail"
      include Truffler::Model

      truffler do
        tenant :account_id
        reads :subject
        label :folder, :choice, question: "Which folder?", options: ->(tenant) { tenant == "1" ? %w[a b] : %w[c d] }
      end
    end
    cache = EncodingCache.new

    assert_not_equal cache.key(model, Query.new("x"), tenant_key: "1"), cache.key(model, Query.new("x"), tenant_key: "2")
  end

  test "writes and reads encodings and query vectors" do
    cache = EncodingCache.new
    encoding = Encoding.new(filters: { needs_action: 0.6 }, keyword_tokens: [])
    cache.write(InboxEmail, "Needs action", encoding, tenant_key: "1")
    cache.write_vector(InboxEmail, "needs action", [ 0.1, 0.2 ], tenant_key: "1")

    assert_equal encoding, cache.read(InboxEmail, Query.new("needs  ACTION"), tenant_key: "1")
    assert_equal [ 0.1, 0.2 ], cache.read_vector(InboxEmail, Query.new("needs action"), tenant_key: "1")
    assert_nil cache.read(InboxEmail, Query.new("something else"), tenant_key: "1")
  end

  test "without a prefetch hook nothing is encoded or reported in flight" do
    Truffler.config.encoding_prefetch = nil
    assert_equal false, EncodingCache.new.prefetch(InboxEmail, Query.new("x"), tenant_key: "1", user_key: "u")
  end

  test "a configured prefetch hook receives the model, query, cache key, tenant, and user" do
    calls = []
    Truffler.config.encoding_prefetch = ->(model, query, **options) { calls << [ model, query.normalized, options ] }
    cache = EncodingCache.new

    assert cache.prefetch(InboxEmail, Query.new("Needs action"), tenant_key: "1", user_key: "u")
    key = cache.key(InboxEmail, Query.new("needs action"), tenant_key: "1")
    assert_equal [ [ InboxEmail, "needs action", { cache_key: key, tenant_key: "1", user_key: "u" } ] ], calls
  end
end
