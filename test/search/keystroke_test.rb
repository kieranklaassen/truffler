require "test_helper"

class SearchKeystrokeTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  test "a scoped model raises MissingScope without a tenant, without a scope, or with another model's relation" do
    assert_raises(Truffler::MissingScope) { InboxEmail.truffler("x", tenant: nil, scope: InboxEmail.all, user: "u") }
    assert_raises(Truffler::MissingScope) { InboxEmail.truffler("x", tenant: 1, scope: nil, user: "u") }
    assert_raises(Truffler::MissingScope) { InboxEmail.truffler("x", tenant: 1, scope: Email.all, user: "u") }
    assert_raises(Truffler::MissingScope) { InboxEmail.truffler("x", tenant: 1, scope: InboxEmail, user: "u") }
  end

  test "the declaration form keeps working beside the search form" do
    assert_instance_of Truffler::Definition, InboxEmail.truffler_definition
    assert_raises(ArgumentError) { InboxEmail.truffler }
    assert_instance_of Truffler::Search::Result, search(InboxEmail, "hello")
  end

  test "records outside the passed scope or in another tenant never appear" do
    mine = inbox_email!(subject: "Invoice due", labels: { needs_action: 0.9 })
    hidden = inbox_email!(subject: "Invoice due", labels: { needs_action: 0.9 })
    other_tenant = inbox_email!(account_id: 2, subject: "Invoice due", labels: { needs_action: 0.9 })
    cache_encoding!(InboxEmail, "invoice", filters: { needs_action: 0.6 })
    cache_encoding!(InboxEmail, "invoice", tenant: "2", filters: { needs_action: 0.6 })

    ids = search(InboxEmail, "invoice", scope: InboxEmail.where.not(id: hidden.id)).records.map(&:id)

    assert_equal [ mine.id ], ids
    assert_not_includes ids, other_tenant.id
    assert_equal [ mine.id, hidden.id ].sort, search(InboxEmail, "due").records.map(&:id).sort
  end

  test "covers AE1: a cached encoding filters on the keystroke, sorts by received_at, shows a chip, and calls no one" do
    now = Time.current
    older = inbox_email!(subject: "Pay the plumber", received_at: now - 2.hours, labels: { needs_action: 0.95 })
    newer = inbox_email!(subject: "Sign the lease", received_at: now - 1.hour, labels: { needs_action: 0.7 })
    inbox_email!(subject: "Newsletter", received_at: now, labels: { needs_action: 0.2 })
    inbox_email!(subject: "Unlabeled", received_at: now)
    query = "emails I need to act on right now"
    cache_encoding!(InboxEmail, query, filters: { needs_action: 0.6 }, keyword_tokens: [], label_term_tokens: %w[need act])

    calls = capture_notifications("truffler.jev_call") { @result = search(InboxEmail, query) }

    assert_equal [ newer.id, older.id ], @result.records.map(&:id)
    assert_equal :cached, @result.encoding_status
    assert_equal [ { key: "needs_action", label: "needs_action", kind: :filter, name: "Needs action" } ], @result.chips
    assert_empty calls
  end

  test "a suppressed filter drops its chip and widens the results" do
    inbox_email!(subject: "Pay the plumber", labels: { needs_action: 0.95 })
    inbox_email!(subject: "Newsletter", labels: { needs_action: 0.2 })
    cache_encoding!(InboxEmail, "act now", filters: { needs_action: 0.6 }, keyword_tokens: [])

    filtered = search(InboxEmail, "act now")
    widened = search(InboxEmail, "act now", suppressed: [ "needs_action" ])

    assert_equal 1, filtered.records.size
    assert_equal 2, widened.records.size
    assert_empty widened.chips
  end

  test "a boost weight ranks the stronger label value first" do
    weak = inbox_email!(subject: "Flight update", labels: { urgent: 0.1 })
    strong = inbox_email!(subject: "Flight update", labels: { urgent: 0.9 })
    cache_encoding!(InboxEmail, "urgent flight", boosts: { urgent: 2.0 }, keyword_tokens: %w[flight], label_term_tokens: %w[urgent])

    result = search(InboxEmail, "urgent flight")

    assert_equal [ strong.id, weak.id ], result.records.map(&:id)
    assert_equal [ { key: "urgent", label: "urgent", kind: :boost, name: "Urgent" } ], result.chips
    assert_in_delta 1.8, result.contributions(strong)["urgent"], 1e-9
    assert_in_delta 0.2, result.contributions(weak.id)["urgent"], 1e-9
  end

  test "scores by weighted dot product, not cosine" do
    keys = %w[needs_action urgent category:billing category:travel category:other importance]
    broad = inbox_email!(subject: "Status", labels: keys.index_with(0.9))
    focused = inbox_email!(subject: "Status", labels: { urgent: 0.6 })
    cache_encoding!(InboxEmail, "urgent", intent_vector: { urgent: 2.0 }, keyword_tokens: [])
    intent = keys.map { |key| key == "urgent" ? 2.0 : 0.0 }
    cosine = ->(values) { Truffler::Embeddings::VectorStore.cosine(intent, keys.map { |key| values.fetch(key, 0.0) }) }

    result = search(InboxEmail, "urgent")

    assert_operator cosine.(keys.index_with(0.9)), :<, cosine.({ "urgent" => 0.6 }), "cosine would rank the focused record first"
    assert_equal [ broad.id, focused.id ], result.records.map(&:id)
    assert_in_delta 1.8, result.score(broad), 1e-9
    assert_in_delta 1.2, result.score(focused), 1e-9
  end

  test "the text term blends with the label term by the declared weights" do
    Truffler.config.vector_store = :ruby
    store = Truffler::Embeddings::VectorStore.for(RecallNote)
    labeled = label!(RecallNote.create!(account_id: 1, title: "Alpha"), pinned: 0.5)
    similar = RecallNote.create!(account_id: 1, title: "Beta")
    store.write(RecallNote, labeled, [ 0.1, 0.995, 0.0 ], fingerprint: "fp")
    store.write(RecallNote, similar, [ 1.0, 0.0, 0.0 ], fingerprint: "fp")
    cache_encoding!(RecallNote, "pinned notes", intent_vector: { pinned: 1.0 }, keyword_tokens: [])
    Truffler::Search::EncodingCache.new.write_vector(RecallNote, "pinned notes", [ 1.0, 0.0, 0.0 ], tenant_key: "1")

    label_only = search(RecallNote, "pinned notes", weights: { text: 0.0 })
    blended = search(RecallNote, "pinned notes", weights: { text: 1.0 })

    assert_equal [ labeled.id, similar.id ], label_only.records.map(&:id)
    assert_equal [ similar.id, labeled.id ], blended.records.map(&:id)
    assert_in_delta 1.0, blended.breakdown(similar)[:text], 0.001
    assert_in_delta 0.5, blended.breakdown(labeled)[:label], 1e-9
  end

  test "covers AE2: with Jev failing and no cached encoding, keyword results still render" do
    Truffler.config.client = Truffler::Clients::Fake.new.fail_with(Truffler::ClientError.new(status: 503))
    match = inbox_email!(subject: "Quarterly invoice")
    inbox_email!(subject: "Lunch")

    result = search(InboxEmail, "invoice")

    assert_equal [ match.id ], result.records.map(&:id)
    assert_includes %i[pending none], result.encoding_status
  end

  test "a cache miss calls the prefetch hook and reports the encoding as pending; a hit does not" do
    calls = []
    Truffler.config.encoding_prefetch = ->(_model, query, **) { calls << query.normalized }
    inbox_email!(subject: "Invoice")

    assert_equal :pending, search(InboxEmail, "Invoice").encoding_status
    cache_encoding!(InboxEmail, "invoice", keyword_tokens: %w[invoice])
    assert_equal :cached, search(InboxEmail, "invoice").encoding_status
    assert_equal [ "invoice" ], calls
  end

  test "covers AE7 recall: vector recall returns a record with no keyword overlap" do
    Truffler.config.vector_store = :ruby
    store = Truffler::Embeddings::VectorStore.for(RecallNote)
    tax = RecallNote.create!(account_id: 1, title: "Q3 filing from Dana")
    store.write(RecallNote, tax, [ 0.9, 0.1, 0.0 ], fingerprint: "fp")
    unrelated = RecallNote.create!(account_id: 1, title: "Dinner plans")
    store.write(RecallNote, unrelated, [ -1.0, 0.0, 0.0 ], fingerprint: "fp")
    query = "the thing from my accountant about taxes"
    Truffler::Search::EncodingCache.new.write_vector(RecallNote, query, [ 1.0, 0.0, 0.0 ], tenant_key: "1")

    result = search(RecallNote, query)

    assert_equal [ tax.id ], result.records.map(&:id)
    assert_includes result.sources, :vector
  end

  test "the exact sender source contributes only when the query holds that exact address" do
    from_accountant = inbox_email!(subject: "Q3 filing", sender_email: "dana@cpa.example")
    inbox_email!(subject: "Q3 filing", sender_email: "someone@else.example")

    assert_empty search(InboxEmail, "taxes dana").records
    exact = search(InboxEmail, "Dana@CPA.example")
    assert_equal [ from_accountant.id ], exact.records.map(&:id)
    assert_includes exact.sources, :exact
  end

  test "invite rows: weak below three results, empty at zero, and encoding pending without local text search" do
    inbox_email!(subject: "Invoice")
    # Email shares the emails table, so InboxEmail sees this row as its second match.
    email = Email.create!(account_id: 1, subject: "Invoice")
    label!(email, needs_action: 0.9)

    assert_equal({ query: "Invoice", reason: :weak }, search(InboxEmail, "Invoice").invite_row)
    assert_equal({ query: "zebra", reason: :empty }, search(InboxEmail, "zebra").invite_row)
    assert_equal({ query: "act now", reason: :encoding_pending }, search(Email, "act now").invite_row)

    cache_encoding!(Email, "act now", filters: { needs_action: 0.6 }, keyword_tokens: [])
    cached = search(Email, "act now")
    assert_equal [ email.id ], cached.records.map(&:id)
    assert_equal :weak, cached.invite_row[:reason]
  end

  test "the declaration sets blend weights and the weak threshold" do
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "emails"
      def self.name = "TunedEmail"
      include Truffler::Model

      truffler do
        tenant :account_id
        reads :subject
        label :urgent, :noul, question: "Is this email time-sensitive?"
        keyword :subject
        ranking text: 0.25, keyword: 2
        weak_below 1
      end
    end
    model.create!(account_id: 1, subject: "Invoice")

    assert_equal({ label: 1.0, text: 0.25, keyword: 2.0, exact: 1.0, min_similarity: 0.0 }, model.truffler_definition.ranking)
    result = search(model, "invoice")
    assert_nil result.invite_row
    assert_equal 2.0, result.breakdown(result.records.first)[:keyword]
    assert_raises(Truffler::DefinitionError) { model.truffler { reads :subject; ranking vibes: 1 } }
  end

  test "three or more results show no invite row" do
    3.times { inbox_email!(subject: "Invoice") }

    assert_nil search(InboxEmail, "invoice").invite_row
  end

  test "a blank query lists the scope by the declared order" do
    older = inbox_email!(received_at: 2.hours.ago)
    newer = inbox_email!(received_at: 1.hour.ago)

    result = search(InboxEmail, "")

    assert_equal [ newer.id, older.id ], result.records.map(&:id)
    assert_equal :none, result.encoding_status
    assert_nil result.invite_row
  end

  test "new matches count records that arrived after the watermark without changing the result" do
    inbox_email!(subject: "Invoice one")
    result = search(InboxEmail, "invoice")
    inbox_email!(subject: "Invoice two")
    inbox_email!(subject: "Invoice three")
    inbox_email!(subject: "Lunch")

    assert_equal 2, InboxEmail.jev_new_matches_count("invoice", tenant: 1, scope: InboxEmail.all, since: result.watermark)
    assert_equal 2, result.new_matches_count
    assert_equal 1, result.records.size
  end

  test "each search emits a summary without query text" do
    inbox_email!(subject: "Invoice")

    payloads = capture_notifications("truffler.search") { search(InboxEmail, "invoice") }

    payload = payloads.sole
    assert_equal "InboxEmail", payload[:record_type]
    assert_equal 1, payload[:result_count]
    assert_equal %w[keyword exact], payload[:sources]
    assert payload.key?(:latency_ms)
    assert_not payload.key?(:query_digest)
    assert_not_includes payload.to_s, "invoice"
  end

  test "the search summary on an encrypted model carries a query digest and no query text" do
    Truffler.config.secret_key_base = "test-secret-key-base"
    SecretNote.create!(account_id: 1, title: "Tax return", body: "private body")

    payloads = capture_notifications("truffler.search") { search(SecretNote, "My Tax Return") }

    payload = payloads.sole
    assert_match(/\A\h{64}\z/, payload[:query_digest])
    assert_equal Truffler::Misses.digest(:query, "my tax return"), payload[:query_digest]
    assert_not_includes payload.to_s.downcase, "tax return"
  end
end
