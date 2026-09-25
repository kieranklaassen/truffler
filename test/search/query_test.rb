require "test_helper"

class SearchQueryTest < Truffler::TestCase
  Query = Truffler::Search::Query

  test "normalizes with NFKC, downcasing, and squished spacing" do
    query = Query.new("  Ｅｍａｉｌｓ   I NEED\tto act ")

    assert_equal "emails i need to act", query.normalized
    assert_equal %w[emails i need to act], query.tokens
    assert_equal "  Ｅｍａｉｌｓ   I NEED\tto act ", query.raw
  end

  test "casing and spacing variants normalize to the same query" do
    assert_equal Query.new("Invoice  from BOB").normalized, Query.new("invoice from bob ").normalized
  end

  test "keeps a quoted phrase as one exact token" do
    query = Query.new('the "Invoice 4471" please')

    assert_equal [ "the", "invoice 4471", "please" ], query.tokens
    assert_equal [ "invoice 4471" ], query.exact_tokens
    assert query.exact_text?
  end

  test "detects digit-bearing tokens, emails, and identifier shapes as exact text" do
    query = Query.new("taxes 2024 from Bob@Example.com about INV-4471 and order_id, ok?")

    assert_equal %w[2024 bob@example.com inv-4471 order_id], query.exact_tokens
    assert_equal %w[taxes 2024 from bob@example.com about inv-4471 and order_id ok], query.tokens
  end

  test "plain words are not exact text" do
    query = Query.new("the thing from my accountant about taxes")

    assert_empty query.exact_tokens
    assert_not query.exact_text?
  end

  test "a blank query has no tokens" do
    assert Query.new("  ").blank?
    assert Query.new(nil).blank?
    assert_empty Query.new(" ").tokens
  end
end
