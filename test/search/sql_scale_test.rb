require "test_helper"

# Keystroke SQL shapes that stay fast on a large tenant: relation sources
# evaluated once, label scores aggregated once, and text similarity read
# from the tenant's top-K neighbors.
class SearchSqlScaleTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  CORRELATED_LABELS = %("truffler_labels"."record_id" = "emails"."id").freeze

  class IdSourceEmail < ActiveRecord::Base
    self.table_name = "emails"
    include Truffler::Model

    truffler do
      tenant :account_id
      reads :subject
      label :urgent, :noul, question: "Is this email time-sensitive?", boost: 2.0
      keyword ->(scope, tokens) { tokens.reduce(scope) { |relation, token| relation.where("LOWER(subject) LIKE ?", "%#{token}%") }.pluck(:id) }
      exact :sender, ->(scope, token) { scope.where(sender_email: token).pluck(:id) }
    end
  end

  def sql_for(model = InboxEmail, query: "x", **encoding)
    Truffler::Search::Sql.new(model, tenant_key: "1", query: Truffler::Search::Query.new(query),
      encoding: Truffler::Search::Encoding.new(**encoding))
  end

  def postgres?
    Truffler::Test::Database.postgres?
  end

  test "label-only ranking aggregates label scores once in a grouped join, not a correlated subquery per row" do
    sql = sql_for(query: "urgent", intent_vector: { urgent: 2.0 }, keyword_tokens: []).relation(InboxEmail.all, limit: 50).to_sql

    assert_match(/LEFT JOIN \(SELECT "truffler_labels"."record_id" AS record_id, SUM\(CASE/, sql)
    assert_match(/GROUP BY "truffler_labels"."record_id"\) "truffler_label_scores"/, sql)
    assert_not_includes sql, CORRELATED_LABELS
  end

  test "a label filter stays one EXISTS while its label scores come from the grouped join" do
    sql = sql_for(query: "act now", filters: { needs_action: 0.6 }, boosts: { urgent: 2.0 }, keyword_tokens: [])
      .relation(InboxEmail.all).to_sql

    assert_match(/GROUP BY "truffler_labels"."record_id"/, sql)
    assert_equal 1, sql.scan(CORRELATED_LABELS).size, sql
  end

  test "grouped label scores rank exactly as before, across tenants and with unlabeled records" do
    broad = inbox_email!(subject: "Status", received_at: 3.hours.ago, labels: { urgent: 0.9, needs_action: 0.9 })
    focused = inbox_email!(subject: "Status", received_at: 2.hours.ago, labels: { urgent: 0.6 })
    bare = inbox_email!(subject: "Status", received_at: 1.hour.ago)
    inbox_email!(account_id: 2, subject: "Status", labels: { urgent: 1.0 })
    cache_encoding!(InboxEmail, "urgent", intent_vector: { urgent: 2.0, needs_action: 1.0 }, keyword_tokens: [])

    result = search(InboxEmail, "urgent")

    assert_equal [ broad.id, focused.id, bare.id ], result.records.map(&:id)
    assert_in_delta 2.7, result.score(broad), 1e-9
    assert_in_delta 1.2, result.score(focused), 1e-9
    assert_in_delta 0.0, result.score(bare), 1e-9
    assert_equal 3, InboxEmail.jev_new_matches_count("urgent", tenant: 1, scope: InboxEmail.all, since: 1.day.ago)
  end

  test "a relation source renders as = ANY(ARRAY(subquery)) on Postgres and IN (subquery) elsewhere" do
    sql = sql_for(query: "dana@cpa.example").relation(InboxEmail.all).to_sql

    if postgres?
      assert_match(/"emails"."id" = ANY\(ARRAY\(SELECT "emails"."id" FROM "emails"/, sql)
      assert_no_match(/"emails"."id" IN \(SELECT/, sql)
    else
      assert_match(/"emails"."id" IN \(SELECT "emails"."id" FROM "emails"/, sql)
    end
  end

  test "keyword and exact callables may return id arrays" do
    hit = IdSourceEmail.create!(account_id: 1, subject: "Invoice 4471")
    sender = IdSourceEmail.create!(account_id: 1, subject: "Lunch", sender_email: "dana@cpa.example")
    IdSourceEmail.create!(account_id: 1, subject: "Lunch")
    IdSourceEmail.create!(account_id: 2, subject: "Invoice 4471")

    sql = sql_for(IdSourceEmail, query: "invoice").relation(IdSourceEmail.all).to_sql

    assert_match(/"emails"."id" IN \(#{hit.id}\)/, sql)
    assert_equal [ hit.id ], search(IdSourceEmail, "invoice").records.map(&:id)
    assert_equal [ sender.id ], search(IdSourceEmail, "dana@cpa.example").records.map(&:id)
    assert_empty search(IdSourceEmail, "zebra").records
  end

  test "config.vector_store accepts a store instance" do
    store = Truffler::Embeddings::RubyStore.new
    Truffler.config.vector_store = store

    assert_same store, Truffler::Embeddings::VectorStore.for(RecallNote)
  end

  test "the Postgres neighbor store joins the tenant's top-K neighbors instead of scoring every row" do
    skip "needs Postgres with pgvector" unless Truffler::Test::Database.pgvector?

    Truffler.config.vector_store = Truffler::Embeddings::NeighborStore.new(k: 2)
    store = Truffler::Embeddings::VectorStore.for(RecallNote)
    near = RecallNote.create!(account_id: 1, title: "Q3 filing")
    close = RecallNote.create!(account_id: 1, title: "Tax receipts")
    far = RecallNote.create!(account_id: 1, title: "Dinner plans")
    other = RecallNote.create!(account_id: 2, title: "Q3 filing")
    { near => [ 1.0, 0.0, 0.0 ], close => [ 0.8, 0.6, 0.0 ], far => [ 0.1, 0.0, 1.0 ], other => [ 1.0, 0.0, 0.0 ] }
      .each { |note, vector| store.write(RecallNote, note, vector, fingerprint: "fp") }
    query = "the thing from my accountant"
    Truffler::Search::EncodingCache.new.write_vector(RecallNote, query, [ 1.0, 0.0, 0.0 ], tenant_key: "1")
    cache_encoding!(RecallNote, query, keyword_tokens: %w[thing])

    sql = Truffler::Search::Sql.new(RecallNote, tenant_key: "1", query: Truffler::Search::Query.new(query),
      vector: [ 1.0, 0.0, 0.0 ], encoding: Truffler::Search::Encoding.new(keyword_tokens: %w[thing])).relation(RecallNote.all).to_sql
    result = search(RecallNote, query)

    assert_match(/LEFT JOIN \(SELECT .* ORDER BY \(truffler_embeddings.embedding <=> .* LIMIT 2\) "truffler_neighbors"/, sql)
    assert_no_match(/truffler_embeddings"?\."?record_id"? = "embedded_notes"."id"/, sql)
    assert_equal [ near.id, close.id ], result.records.map(&:id)
    assert_in_delta 1.0, result.breakdown(near)[:text], 0.001
    assert_includes result.sources, :vector
  end

  test "postgres smoke: label-only ranking over 20k records plans no per-row subquery and stays fast" do
    skip "Postgres only" unless postgres?

    now = Time.current
    ids = InboxEmail.insert_all(Array.new(20_000) { |index| { account_id: 1, subject: "Email #{index}", received_at: now - index.minutes,
      created_at: now, updated_at: now } }, returning: :id).rows.flatten
    labels = ids.flat_map do |id|
      %w[urgent needs_action].map do |key|
        { record_type: "InboxEmail", record_id: id, tenant_key: "1", label_key: key, value: (id % 97) / 97.0, fingerprint: "fp",
          labeled_at: now }
      end
    end
    labels.each_slice(10_000) { |slice| Truffler::Records::Label.insert_all(slice) }
    ActiveRecord::Base.connection.execute("ANALYZE emails, truffler_labels")
    cache_encoding!(InboxEmail, "urgent", intent_vector: { urgent: 2.0, needs_action: 1.0 }, keyword_tokens: [])

    sql = sql_for(query: "urgent", intent_vector: { urgent: 2.0, needs_action: 1.0 }, keyword_tokens: [])
      .relation(InboxEmail.where(account_id: 1), limit: 50).to_sql
    plan = ActiveRecord::Base.connection.select_values("EXPLAIN #{sql}").join("\n")
    search(InboxEmail, "urgent")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = search(InboxEmail, "urgent")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_no_match(/SubPlan/, plan)
    assert_equal 50, result.records.size
    assert_in_delta 3 * 96 / 97.0, result.score(result.records.first), 1e-6
    assert_operator elapsed, :<, 2.0, "label-only keystroke over 20k records took #{elapsed.round(3)} s"
  end
end
