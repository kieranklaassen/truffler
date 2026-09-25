require "test_helper"

class ProvidersBackupTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  FakeGmail = Truffler::Test::FakeGmail
  FakeRun = Truffler::Test::FakeRun

  setup do
    @run_finder = Truffler::Providers.run_finder
    Truffler::Providers.run_finder = ->(id) { FakeRun.find(id) }
    FakeGmail.current = FakeGmail.new("1" => [ { id: "g-4471", subject: "Invoice 4471 from Acme" } ],
      "2" => [ { id: "g-other", subject: "Invoice 4471 duplicate" } ])
  end

  teardown do
    Truffler::Providers.run_finder = @run_finder
    FakeRun.clear
    FakeGmail.current = nil
  end

  def start(run, query: run.query, tenant_key: "1", user_key: "user-1", **options)
    Truffler::Providers.start(run, query: query, tenant_key: tenant_key, user_key: user_key, **options)
  end

  def smart_section
    { status: :done, buckets: { strong: [ { id: 7, score: 0.9 } ], possible: [], unlikely: [] } }
  end

  test "covers AE3: exact text on a model with no local text search runs Gmail in its own section, local sections untouched" do
    inbox_email!(subject: "Invoice 4471 from Acme")
    keystroke = GmailEmail.truffler("invoice 4471", tenant: 1, scope: GmailEmail.all, user: "user-1")
    run = FakeRun.new(model: GmailEmail, query: "invoice 4471", candidate_ids: keystroke.ids, sections: { smart: smart_section })

    assert_equal :exact_text, start(run, local_result: keystroke)
    assert_equal({ status: :pending, name: "gmail", label: "Gmail" }, run.sections[:provider])
    perform_enqueued_jobs(only: Truffler::Jobs::ProviderSearchJob)

    provider = run.sections[:provider]
    assert_equal :results, provider[:status]
    assert_equal "Gmail", provider[:label]
    assert_equal [ "g-4471" ], provider[:results].map { |message| message[:id] }
    assert_equal smart_section, run.sections[:smart]
    assert_equal [ :provider, :provider ], run.updates.map(&:first)
    assert_equal keystroke.ids, GmailEmail.truffler("invoice 4471", tenant: 1, scope: GmailEmail.all, user: "user-1").ids
  end

  test "quoted phrases, identifiers, and emails count as exact text even with strong local results" do
    [ '"quarterly report"', "INV-4471", "billing@acme.test" ].each do |query|
      run = FakeRun.new(model: LocalProviderEmail, query: query, candidate_ids: (1..10).to_a)

      assert_equal :exact_text, start(run), query
    end
    assert_enqueued_jobs 3, only: Truffler::Jobs::ProviderSearchJob
  end

  test "an intent query with strong local results does not run the provider and leaves its section idle" do
    run = FakeRun.new(model: LocalProviderEmail, query: "emails I need to act on", candidate_ids: (1..10).to_a)

    assert_nil start(run)
    assert_no_enqueued_jobs only: Truffler::Jobs::ProviderSearchJob
    assert_empty run.updates
    assert_nil run.sections[:provider]
  end

  test "an intent query with fewer local results than weak_below runs the provider" do
    run = FakeRun.new(model: LocalProviderEmail, query: "emails I need to act on", candidate_ids: [ 1, 2 ])

    assert_equal :weak_local, start(run)
    assert_enqueued_jobs 1, only: Truffler::Jobs::ProviderSearchJob
  end

  test "the keystroke result's invite row decides weakness when passed, including a pending encoding with no local text" do
    3.times { |index| inbox_email!(subject: "Invoice #{index}") }
    strong = LocalProviderEmail.truffler("invoice", tenant: 1, scope: LocalProviderEmail.all, user: "user-1")
    weak = LocalProviderEmail.truffler("acme", tenant: 1, scope: LocalProviderEmail.all, user: "user-1")
    pending = GmailEmail.truffler("things to act on", tenant: 1, scope: GmailEmail.all, user: "user-1")

    assert_nil start(FakeRun.new(model: LocalProviderEmail, query: "invoice"), local_result: strong)
    assert_equal :weak_local, start(FakeRun.new(model: LocalProviderEmail, query: "acme"), local_result: weak)
    assert_equal :encoding_pending, pending.invite_row[:reason]
    assert_equal :weak_local, start(FakeRun.new(model: GmailEmail, query: "things to act on"), local_result: pending)
  end

  test "a model with no provider declared never enqueues the job or writes the section" do
    run = FakeRun.new(model: InboxEmail, query: "invoice 4471")

    assert_nil start(run)
    assert_no_enqueued_jobs only: Truffler::Jobs::ProviderSearchJob
    assert_empty run.updates
  end

  test "a blank query never runs the provider" do
    assert_nil start(FakeRun.new(model: GmailEmail, query: "   "))
    assert_no_enqueued_jobs
  end

  test "without local_result the run must expose candidate_ids" do
    run = Struct.new(:id, :model, :query).new("r1", LocalProviderEmail, "act on")

    assert_raises(ArgumentError) { start(run) }
  end

  test "job arguments carry the run id and keys only, never the query text" do
    run = FakeRun.new(model: GmailEmail, query: "invoice 4471 from Acme")
    start(run)

    args = enqueued_jobs.last[:args]
    assert_equal [ run.id, "1", "user-1" ], args
    assert_not_includes args.to_json, "invoice"
  end

  test "the start notification is allowlisted and carries the decision, not the query" do
    run = FakeRun.new(model: GmailEmail, query: "invoice 4471")

    payloads = capture_notifications("truffler.provider_start") { start(run) }

    assert_equal 1, payloads.size
    assert_equal({ run_id: run.id, record_type: "GmailEmail", tenant_key: "1", user_key: "user-1", section: "provider",
      outcome: :enqueued, reason: :exact_text }, payloads.first)
    assert_not_includes payloads.to_json, "invoice"
  end
end
