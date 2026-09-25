require "test_helper"

class SearchSqlTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  def sql_for(encoding: Truffler::Search::Encoding.new, query: "x", weights: {})
    definition = InboxEmail.truffler_definition
    Truffler::Search::Sql.new(InboxEmail, tenant_key: "1", query: Truffler::Search::Query.new(query), encoding: encoding,
      weights: definition.ranking.merge(weights))
  end

  def selects_during
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  test "the label term is SUM(weight * value) over the intent's nonzero keys only" do
    sql = sql_for(encoding: Truffler::Search::Encoding.new(intent_vector: { urgent: 2.0, "category:billing" => 0.5, importance: 0 }))
      .label_score_sql

    assert_match(/SUM\(CASE/, sql)
    assert_includes sql, "'urgent'"
    assert_includes sql, "'category:billing'"
    assert_not_includes sql, "importance"
    assert_nil sql_for.label_score_sql
  end

  test "hard filters are EXISTS subqueries on truffler_labels within the model and tenant" do
    sql = sql_for(encoding: Truffler::Search::Encoding.new(filters: { needs_action: 0.6 })).relation(InboxEmail.all).to_sql

    assert_match(/EXISTS \(SELECT 1 FROM "truffler_labels"/, sql)
    assert_includes sql, "\"truffler_labels\".\"record_type\" = 'InboxEmail'"
    assert_includes sql, "\"truffler_labels\".\"tenant_key\" = '1'"
    assert_includes sql, "\"truffler_labels\".\"value\" >= 0.6"
  end

  test "keyword LIKE escapes wildcards in query tokens" do
    inbox_email!(subject: "Ratio 5x6 and abc")
    percent = inbox_email!(subject: "Ratio 5%6")
    underscore = inbox_email!(subject: "Field a_c")

    assert_equal [ percent.id ], search(InboxEmail, "5%6").records.map(&:id)
    assert_equal [ underscore.id ], search(InboxEmail, "a_c").records.map(&:id)
  end

  test "0.1.1: with a label filter applied, keywords only add to the score instead of being required" do
    hit = inbox_email!(subject: "Needs action now", labels: { needs_action: 0.7 })
    miss = inbox_email!(subject: "Pay the plumber", labels: { needs_action: 0.9 })
    inbox_email!(subject: "Needs action now", labels: { needs_action: 0.1 })
    cache_encoding!(InboxEmail, "needs action now", filters: { needs_action: 0.6 }, keyword_tokens: %w[needs action now])

    assert_equal [ hit.id, miss.id ], search(InboxEmail, "needs action now").records.map(&:id)
  end

  test "0.1.1: without a label filter, keywords stay required" do
    hit = inbox_email!(subject: "Flight update", labels: { urgent: 0.1 })
    inbox_email!(subject: "Lunch", labels: { urgent: 0.9 })
    cache_encoding!(InboxEmail, "urgent flight", boosts: { urgent: 2.0 }, keyword_tokens: %w[flight])

    assert_equal [ hit.id ], search(InboxEmail, "urgent flight").records.map(&:id)
  end

  test "a keystroke search runs one SELECT and makes no network call" do
    inbox_email!(subject: "Invoice", labels: { needs_action: 0.9, urgent: 0.4 })
    cache_encoding!(InboxEmail, "urgent invoice", filters: { needs_action: 0.6 }, boosts: { urgent: 2.0 },
      keyword_tokens: %w[invoice], label_term_tokens: %w[urgent])

    statements = selects_during { @result = search(InboxEmail, "urgent invoice") }

    assert_equal 1, statements.size, statements.join("\n")
    assert_equal 1, @result.records.size
  end
end
