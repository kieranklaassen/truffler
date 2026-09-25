require "test_helper"

class SmartSearchRunTest < Truffler::TestCase
  include Truffler::Test::SmartSearchHelpers

  Run = Truffler::SmartSearch::Run

  setup do
    @cable = Truffler::Test::FakeCable.new
    Truffler.config.broadcaster = @cable
    Truffler.config.encoding_prefetch = nil
  end

  test "starting a run reserves the Smart section with every bucket pending and leaves the keystroke result unchanged" do
    3.times { |index| inbox_email!(subject: "invoice #{index}", received_at: index.hours.ago) }
    before = search(InboxEmail, "invoice")

    run = smart(InboxEmail, "invoice")

    assert run.reserved?
    assert_equal :pending, run.status
    assert_equal 3, run.reserved_slots
    Truffler::SmartSearch::BUCKETS.each { |bucket| assert run.pending?(bucket) }
    assert_equal({ strong: [], possible: [], unlikely: [] }, run.buckets)
    assert_equal before.ids, search(InboxEmail, "invoice").ids
    assert_equal [ [ run.id ] ], smart_job_args
  end

  test "covers AE7: the accountant's tax email lands in Strong and is promoted in the keystroke list" do
    tax = inbox_email!(subject: "Your taxes from the accountant", body: "file taxes")
    other = inbox_email!(subject: "Lunch taxes?", body: "taxes")
    Truffler.config.client = client = rerank_client({ "accountant" => 0.9, "Lunch" => 0.2 })

    run = smart(InboxEmail, "taxes")
    drain_jobs

    assert_equal :complete, run.status
    assert_equal [ { id: tax.id, score: 0.9 } ], run.buckets[:strong]
    assert_equal [ { id: other.id, score: 0.2 } ], run.buckets[:unlikely]
    assert_equal [ tax.id ], run.promoted_ids
    assert_equal [ tax.id ], search(InboxEmail, "taxes").promoted_ids(run)
    assert_equal 1, rerank_calls(client).size
    assert_not run.pending?(:strong)
  end

  test "buckets append in chunk arrival order and entries shown earlier keep their positions" do
    Truffler.config.rerank_chunk_size = 2
    emails = 6.times.map { |index| inbox_email!(subject: "report #{index}", received_at: index.hours.ago) }
    Truffler.config.client = rerank_client({ "report" => 0.8 })
    run = smart(InboxEmail, "report")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)
    chunks = run.chunk_count.times.map { |index| run.chunk_ids(index) }
    assert_equal 3, chunks.size

    Truffler::SmartSearch::Reranker.new.call(run, 1)
    shown = run.buckets[:strong].map { |entry| entry[:id] }
    assert_equal chunks[1], shown

    Truffler::SmartSearch::Reranker.new.call(run, 0)
    Truffler::SmartSearch::Reranker.new.call(run, 2)

    strong = run.buckets[:strong].map { |entry| entry[:id] }
    assert_equal shown, strong.first(2)
    assert_equal chunks[1] + chunks[0] + chunks[2], strong
    assert_equal emails.map(&:id).sort, strong.sort
  end

  test "covers AE5: with no rerank budget the run is paused, no chunks run, a ping is sent, and the result says so" do
    inbox_email!(subject: "invoice")
    Truffler.config.client = client = rerank_client
    run = smart(InboxEmail, "invoice")
    budget = Truffler::Test::DeniedBudget.new

    Truffler::SmartSearch::Dispatcher.new(budget: budget).call(run)

    assert_equal :paused, run.status
    assert run.paused?
    assert_not run.pending?
    assert_equal [ { priority: :rerank, user_key: "user-1" } ], budget.calls
    assert_empty enqueued_jobs.select { |job| job[:job] == Truffler::Jobs::RerankChunkJob }
    assert_equal [ "smart" ], @cable.sections
    assert search(InboxEmail, "invoice").smart_ranking_paused?(run)
    assert run.to_h[:paused]
    assert_empty rerank_calls(client)
  end

  test "the per-user rerank cap pauses the eleventh run in a minute (R26)" do
    inbox_email!(subject: "invoice")
    Truffler.config.client = rerank_client
    runs = 11.times.map do
      run = smart(InboxEmail, "invoice", surface: nil)
      perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)
      run
    end

    assert runs.first(10).all?(&:plan)
    assert_nil runs.last.plan
    assert_equal :paused, runs.last.status
  end

  test "covers AE8: a new run for the same searcher cancels the old one, whose chunks make no Jev call" do
    5.times { |index| inbox_email!(subject: "invoice #{index}") }
    Truffler.config.client = client = rerank_client({ "invoice" => 0.9 })
    old = smart(InboxEmail, "invoice")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)
    Truffler::SmartSearch::Reranker.new.call(old, 0)
    assert_not_empty old.buckets[:strong]
    keystroke = search(InboxEmail, "invoice").ids

    fresh = smart(InboxEmail, "invoic")

    assert_equal :cancelled, old.status
    assert_not old.reserved?
    assert_equal({ strong: [], possible: [], unlikely: [] }, old.buckets)
    assert_equal :skipped, Truffler::SmartSearch::Reranker.new.call(old, 0)
    assert_equal 1, rerank_calls(client).size
    assert_equal keystroke, search(InboxEmail, "invoice").ids
    assert fresh.reserved?
  end

  test "a query edit or chip change cancels the in-flight run and clears its buckets (R24)" do
    inbox_email!(subject: "invoice", labels: { needs_action: 0.9 })
    Truffler.config.client = rerank_client({ "invoice" => 0.9 })
    run = smart(InboxEmail, "invoice", surface: "palette")
    drain_jobs
    assert_not_empty run.buckets[:strong]

    InboxEmail.jev_cancel_smart_search(tenant: 1, user: "user-1", surface: "palette")

    assert_equal :cancelled, run.status
    assert_equal({ strong: [], possible: [], unlikely: [] }, run.buckets)

    chip_run = smart(InboxEmail, "invoice", surface: "palette")
    smart(InboxEmail, "invoice", surface: "palette", suppressed: [ "needs_action" ])
    assert chip_run.cancelled?
  end

  test "runs for another surface or user are not superseded" do
    inbox_email!(subject: "invoice")
    palette = smart(InboxEmail, "invoice", surface: "palette")
    smart(InboxEmail, "invoice")
    smart(InboxEmail, "invoice", surface: "palette", user: "user-2")

    assert_not palette.cancelled?
  end

  test "cancel! during an in-flight chunk discards that chunk's answers on return" do
    inbox_email!(subject: "invoice")
    run = smart(InboxEmail, "invoice")
    Truffler.config.client = Truffler::Clients::Fake.new.answer(:relevance) do
      run.cancel!
      0.9
    end
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)

    assert_equal :cancelled, Truffler::SmartSearch::Reranker.new.call(run, 0)
    assert_equal :cancelled, run.status
    assert_nil run.chunk(0)
    assert_equal [], run.buckets[:strong]
  end

  test "no strong matches once every chunk resolved with Strong empty, and Unlikely collapses by default" do
    inbox_email!(subject: "invoice a")
    inbox_email!(subject: "invoice b")
    Truffler.config.client = rerank_client({ "invoice a" => 0.5 }, default: 0.1)
    run = smart(InboxEmail, "invoice")
    assert_not run.no_strong_matches?

    drain_jobs

    assert run.no_strong_matches?
    assert_equal 1, run.buckets[:possible].size
    assert_equal 1, run.buckets[:unlikely].size
    assert_equal [ :unlikely ], run.collapsed_by_default
    assert run.collapsed?(:unlikely)
    assert_not run.collapsed?(:strong)
    assert run.to_h[:no_strong_matches]
  end

  test "a Jev failure marks the chunk failed, resolves the buckets, and pings" do
    inbox_email!(subject: "invoice")
    Truffler.config.client = Truffler::Clients::Fake.new.fail_with(RuntimeError.new("boom"))
    run = smart(InboxEmail, "invoice")

    drain_jobs

    assert_equal :complete, run.status
    assert_equal "failed", run.chunk(0)["status"]
    assert_equal "Truffler::ClientError", run.chunk(0)["error_class"]
    assert_equal [ "smart" ], @cable.sections
  end

  test "candidates split into chunks of 10 with one relevance noul per candidate and one request per chunk" do
    25.times { |index| inbox_email!(subject: "memo #{index}", received_at: index.minutes.ago) }
    Truffler.config.client = client = rerank_client({ "memo" => 0.4 })

    run = smart(InboxEmail, "memo")
    drain_jobs

    calls = rerank_calls(client)
    assert_equal [ 10, 10, 5 ], calls.map { |call| call[:questions].size }
    assert calls.all? { |call| call[:questions].keys.all? { |id| id.end_with?("__relevance") } }
    assert calls.all? { |call| call[:questions].values.all? { |question| question["type"] == "noul" } }
    assert_equal 25, run.buckets[:possible].size
    assert_equal %w[smart smart smart], @cable.sections
  end

  test "rerank depth caps the candidates (default 30)" do
    35.times { |index| inbox_email!(subject: "memo #{index}") }
    Truffler.config.client = client = rerank_client

    run = smart(InboxEmail, "memo")
    drain_jobs

    assert_equal 30, run.candidate_ids.size
    assert_equal 3, rerank_calls(client).size
  end

  test "covers AE10: choosing the Smart search row streams results with the needs-action filter applied" do
    Truffler.config.encoding_prefetch = Truffler::QueryEncoding::Prefetch.new
    act = label!(Email.create!(account_id: 1, subject: "Please sign the lease", received_at: 1.hour.ago), needs_action: 0.9)
    label!(Email.create!(account_id: 1, subject: "Weekly digest", received_at: 2.hours.ago), needs_action: 0.1)
    query = "emails I need to act on right now"
    clear_enqueued_jobs
    Truffler.config.client = client = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => "none", "token" => "filler" }[tag] }
    client.answer("intent__needs_action", "filter").answer(:relevance, 0.9)

    keystroke = search(Email, query)
    assert_equal({ query: query, reason: :encoding_pending }, keystroke.invite_row)
    run = smart(Email, query)
    drain_jobs

    assert_equal [ act.id ], run.candidate_ids
    assert_equal [ "needs_action" ], run.applied_filters
    assert_equal [ act.id ], run.buckets[:strong].map { |entry| entry[:id] }
    assert_equal [ act.id ], search(Email, query).ids
    assert_equal [], keystroke.ids
  end

  test "the run waits for an in-flight encoding within the deadline and reranks only candidates passing its filter" do
    act = label!(Email.create!(account_id: 1, subject: "Sign it", received_at: 1.hour.ago), needs_action: 0.9)
    label!(Email.create!(account_id: 1, subject: "Digest", received_at: 2.hours.ago), needs_action: 0.1)
    query = Truffler::Search::Query.new("needs action")
    run = smart(Email, query.raw)
    encodings = Truffler::QueryEncoding::Cache.new
    key = encodings.key(Email, query, tenant_key: "1")
    encodings.claim(key)
    now = 0.0
    sleeper = lambda do |seconds|
      now += seconds
      encodings.write(Email, query, Truffler::Search::Encoding.new(filters: { "needs_action" => 0.6 }), tenant_key: "1") if now >= 0.5
    end
    encoder = Truffler::QueryEncoding::Encoder.new(clock: -> { now }, sleeper: sleeper)

    Truffler::SmartSearch::Dispatcher.new(encoder: encoder, deadline: 1.0).call(run)

    assert_equal [ act.id ], run.candidate_ids
    assert_operator now, :<, 1.0
  end

  test "past the encoding deadline the run proceeds without the encoding" do
    Email.create!(account_id: 1, subject: "Sign it")
    Email.create!(account_id: 1, subject: "Digest")
    query = Truffler::Search::Query.new("needs action")
    run = smart(Email, query.raw)
    encodings = Truffler::QueryEncoding::Cache.new
    encodings.claim(encodings.key(Email, query, tenant_key: "1"))
    now = 0.0
    encoder = Truffler::QueryEncoding::Encoder.new(clock: -> { now }, sleeper: ->(seconds) { now += seconds })

    Truffler::SmartSearch::Dispatcher.new(encoder: encoder, deadline: 1.0).call(run)

    assert_equal 2, run.candidate_ids.size
    assert_equal [], run.applied_filters
    assert_in_delta 1.0, now
  end

  test "candidates outside the scope snapshot or tenant are never sent to Jev" do
    inside = inbox_email!(subject: "invoice mine")
    hidden = inbox_email!(subject: "invoice hidden")
    other_tenant = inbox_email!(subject: "invoice other", account_id: 2)
    Truffler.config.client = client = rerank_client

    run = smart(InboxEmail, "invoice", scope: InboxEmail.where.not(id: hidden.id))
    drain_jobs

    assert_equal [ inside.id ], run.candidate_ids
    sent = rerank_calls(client).flat_map { |call| call[:state]["candidates"].values.map { |fields| fields["subject"] } }
    assert_equal [ "invoice mine" ], sent
    assert_not_includes run.pool_ids, other_tenant.id
  end

  test "an expired run reads as expired and is no longer reserved" do
    inbox_email!(subject: "invoice")
    run = smart(InboxEmail, "invoice")

    travel 16.minutes do
      found = Truffler::SmartSearch.find(run.id)
      assert found.expired?
      assert_equal :expired, found.status
      assert_not found.reserved?
      assert_equal 0, found.reserved_slots
      assert_nil Truffler::Jobs::SmartSearchJob.perform_now(run.id)
    end
  end

  test "the surface's explicit action rides on the result and the run (R23)" do
    inbox_email!(subject: "invoice")

    assert_equal :row, search(InboxEmail, "invoice", surface: "palette").explicit_action
    assert_equal :row, smart(InboxEmail, "invoice", surface: "palette").explicit_action
  end

  test "on an encrypted model the cached run holds the query encrypted and jobs carry only the run id" do
    Truffler.config.secret_key_base = "test-secret-key-base"
    SecretNote.create!(account_id: 1, title: "rent", body: "pay the landlord")

    run = SecretNote.jev_smart_search("landlord rent overdue", tenant: 1, scope: SecretNote.all, user: "user-1")

    raw = Truffler.config.cache_store.read("truffler/smart/run/#{run.id}")
    assert raw["encrypted"]
    assert_not_includes Marshal.dump(raw), "landlord"
    assert_equal "landlord rent overdue", Run.find(run.id).query
    assert_equal [ [ run.id ] ], smart_job_args
  end

  test "the host prop is data only: buckets, pending flags, collapsed buckets, promoted ids, and sections" do
    email = inbox_email!(subject: "invoice")
    Truffler.config.client = rerank_client({ "invoice" => 0.9 })
    run = smart(InboxEmail, "invoice")
    drain_jobs

    props = run.to_h
    assert_equal run.id, props[:run_id]
    assert_equal :complete, props[:status]
    assert_equal [ { id: email.id, score: 0.9 } ], props[:buckets][:strong]
    assert_equal({ strong: false, possible: false, unlikely: false }, props[:pending])
    assert_equal [ :unlikely ], props[:collapsed]
    assert_equal [ email.id ], props[:promoted_ids]
    assert_equal({ provider: { status: :absent } }, props[:sections])
    assert_equal props.as_json, run.as_json
  end
end
