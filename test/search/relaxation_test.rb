require "test_helper"

class RelaxedTicket < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject, :body
    label :product, :choice, question: "Which product is this about?", options: %w[cora jev], filter_at: 0.5
    label :source, :choice, question: "Where did this come from?", options: %w[email chat], filter_at: 0.5
    keyword :subject, :body
    order :received_at, :desc
  end
end

class SearchRelaxationTest < Truffler::TestCase
  include Truffler::Test::SmartSearchHelpers

  CORA_EMAIL = { filters: { "product:cora" => 0.5, "source:email" => 0.5 }, keyword_tokens: [],
                 label_term_tokens: %w[cora email], label_term_sources: { "cora" => %w[product:cora], "email" => %w[source:email] } }.freeze

  setup do
    Truffler.config.encoding_prefetch = nil
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new
  end

  def ticket!(subject, labels = {}, received_at: Time.current)
    label!(RelaxedTicket.create!(account_id: 1, subject: subject, body: "", received_at: received_at), labels)
  end

  def selects_during
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  test "0.1.6: a filter no record in the tenant has is relaxed, its word comes back as a keyword, and the product filter stays" do
    bounced = ticket!("Customer email bounced", { "product:cora" => 0.9, "source:chat" => 0.9 }, received_at: 2.hours.ago)
    login = ticket!("Login fails", { "product:cora" => 0.9, "source:chat" => 0.8 }, received_at: 1.hour.ago)
    ticket!("Email sync broken", { "product:jev" => 0.9, "source:chat" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora email", **CORA_EMAIL)

    statements = selects_during { @result = search(RelaxedTicket, "cora email") }

    assert_equal [ bounced.id, login.id ], @result.ids
    assert_equal [ "source:email" ], @result.relaxed_labels
    assert_equal({ "product:cora" => 0.5 }, @result.encoding.filters)
    assert_includes @result.encoding.intent_vector.keys, "source:email"
    assert_includes @result.encoding.keywords(Truffler::Search::Query.new("cora email")), "email"
    assert_equal [
      { key: "product:cora", label: "product", kind: :filter, name: "Product: cora" },
      { key: "source:email", label: "source", kind: :filter, name: "Source: email", relaxed: true }
    ], @result.chips
    assert_equal 2, statements.size, statements.join("\n")
  end

  test "0.1.6: zero results with no keyword matches stay empty and relax nothing" do
    ticket!("Login fails", { "product:jev" => 0.9, "source:chat" => 0.9 })
    cache_encoding!(RelaxedTicket, "email", filters: { "source:email" => 0.5 }, keyword_tokens: [], label_term_tokens: %w[email],
      label_term_sources: { "email" => %w[source:email] })

    result = search(RelaxedTicket, "email")

    assert_empty result.records
    assert_empty result.relaxed_labels
    assert_equal [ { key: "source:email", label: "source", kind: :filter, name: "Source: email" } ], result.chips
  end

  test "0.1.6: a filter that gives back no word is not relaxed into every record in the tenant" do
    ticket!("Login fails", { "product:cora" => 0.9 })
    cache_encoding!(RelaxedTicket, "chat stuff", filters: { "source:chat" => 0.5 }, keyword_tokens: [], filler_tokens: %w[stuff])

    statements = selects_during { @result = search(RelaxedTicket, "chat stuff") }

    assert_empty @result.records
    assert_empty @result.relaxed_labels
    assert_equal 1, statements.size, statements.join("\n")
  end

  test "0.1.6: when relaxing only the missing filters still finds nothing, every Jev filter is relaxed" do
    ticket!("Cora login", { "product:cora" => 0.9, "source:email" => 0.9 })
    ticket!("Jev chat", { "product:jev" => 0.9, "source:chat" => 0.9 })
    both = ticket!("Cora chat export", { "product:jev" => 0.9, "source:email" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora chat", filters: { "product:cora" => 0.5, "source:chat" => 0.5 }, keyword_tokens: [],
      label_term_tokens: %w[cora chat], label_term_sources: { "cora" => %w[product:cora], "chat" => %w[source:chat] })

    result = search(RelaxedTicket, "cora chat")

    assert_equal [ both.id ], result.ids
    assert_equal %w[product:cora source:chat], result.relaxed_labels.sort
    assert_empty result.encoding.filters
    assert(result.chips.all? { |chip| chip[:relaxed] })
  end

  test "0.1.6: a non-empty search is unchanged, relaxes nothing, and stays one SELECT" do
    email = ticket!("Email bounced", { "product:cora" => 0.9, "source:email" => 0.9 })
    ticket!("Login fails", { "product:cora" => 0.9, "source:chat" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora email", **CORA_EMAIL)

    statements = selects_during { @result = search(RelaxedTicket, "cora email") }

    assert_equal [ email.id ], @result.ids
    assert_empty @result.relaxed_labels
    assert(@result.chips.none? { |chip| chip.key?(:relaxed) })
    assert_equal 1, statements.size, statements.join("\n")
  end

  test "0.1.6: a chip the searcher suppressed stays suppressed while another filter relaxes" do
    cora = ticket!("Cora email bounced", { "product:cora" => 0.9 })
    jev = ticket!("Cora email sync", { "product:jev" => 0.9 }, received_at: 1.hour.ago)
    ticket!("Login fails", { "product:jev" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora email", **CORA_EMAIL)

    result = search(RelaxedTicket, "cora email", suppressed: [ "product" ])

    assert_equal [ cora.id, jev.id ], result.ids
    assert_equal [ "source:email" ], result.relaxed_labels
    assert_equal [ "source:email" ], result.chips.map { |chip| chip[:key] }
    assert_not_includes result.encoding.intent_vector.keys, "product:cora"
  end

  test "0.1.6: a relaxed search counts new matches with the relaxed encoding" do
    ticket!("Customer email bounced", { "product:cora" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora email", **CORA_EMAIL)

    result = search(RelaxedTicket, "cora email")
    travel 1.minute do
      ticket!("Another email", { "product:cora" => 0.9 })
    end

    assert_equal 1, result.new_matches_count
  end

  test "0.1.6: Smart search relaxes candidate filters instead of reranking an empty set, and records the relaxed labels" do
    bounced = ticket!("Customer email bounced", { "product:cora" => 0.9 }, received_at: 2.hours.ago)
    login = ticket!("Login fails", { "product:cora" => 0.9 }, received_at: 1.hour.ago)
    ticket!("Email sync broken", { "product:jev" => 0.9 })
    cache_encoding!(RelaxedTicket, "cora email", **CORA_EMAIL)
    clear_enqueued_jobs
    Truffler.config.client = client = rerank_client({ "bounced" => 0.9 })

    run = smart(RelaxedTicket, "cora email")
    drain_jobs

    assert_equal [ bounced.id, login.id ], run.candidate_ids
    assert_equal [ "product:cora" ], run.applied_filters
    assert_equal [ "source:email" ], run.relaxed_labels
    assert_equal [ "source:email" ], run.to_h[:relaxed_labels]
    assert_equal [ { id: bounced.id, score: 0.9 } ], run.buckets[:strong]
    assert_equal 1, rerank_calls(client).size
  end
end
