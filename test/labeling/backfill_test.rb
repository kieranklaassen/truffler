require "test_helper"

class BackfillTest < Truffler::TestCase
  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState
  Backfill = Truffler::Labeling::Backfill

  # Fails every call after the first `succeed` calls, like a Jev outage that
  # starts partway through a run.
  class FlakyClient < Truffler::Clients::Fake
    def initialize(succeed:)
      super()
      @succeed = succeed
    end

    def perform(**)
      raise Truffler::Test::HttpError.new(503, "Service Unavailable") if calls.size >= @succeed

      super
    end
  end

  setup do
    @fake = Truffler::Clients::Fake.new
    @fake.answer(:needs_action, 0.8).answer(:urgent, 0.9)
    Truffler.config.client = @fake
    @original = Email.truffler_definition
  end

  teardown do
    Email.truffler_definition = @original
  end

  def create_emails(count, account_id: 1)
    Array.new(count) { Email.create!(account_id: account_id, subject: "Invoice", body: "Pay it", sender_name: "Ann") }
  end

  def reword_urgent
    reworded = @original.dup
    urgent = Truffler::LabelDefinition.new(:urgent, :noul, question: "Is this email due within a day?", boost: 2.0)
    reworded.instance_variable_set(:@labels, @original.labels.merge("urgent" => urgent))
    Email.truffler_definition = reworded
  end

  def version(tenant_key = "1")
    Email.truffler_definition.vocabulary.version(tenant_key: tenant_key)
  end

  def fingerprint(key)
    Email.truffler_definition.vocabulary.fingerprint(key)
  end

  def labeled_tags
    @fake.calls.sum { |call| call[:state]["records"].size }
  end

  def request_cost(count)
    records = Email.order(:id).first(count).map { |email| [ email, Email.truffler_definition.label_keys ] }
    request = Truffler::Labeling::RequestBuilder.new(Email.truffler_definition, tenant_key: "1").build(records).sole
    Truffler.config.cost_for(Truffler::Tokens.estimate({ state: request.state, questions: request.questions }))
  end

  test "labels records that have no state row, newest first, packed per tenant" do
    emails = create_emails(3)
    State.delete_all

    result = Backfill.new(Email, batch_size: 10).run

    assert_equal [ :complete, 3, 1 ], [ result.status, result.labeled, result.requests ]
    assert_equal [ 1, 3 ], [ @fake.calls.size, labeled_tags ]
    assert_equal [ [ "labeled", version ] ] * 3, State.pluck(:status, :vocabulary_version)
    assert_equal emails.map(&:id).sort, State.pluck(:record_id).sort
    assert_nil result.cursor
  end

  test "covers AE4: a reworded question relabels new records live first and keeps stale labels usable" do
    old = create_emails(2)
    perform_enqueued_jobs
    reword_urgent

    fresh = create_emails(1).sole
    perform_enqueued_jobs

    assert_equal fingerprint(:urgent), Label.find_by!(record_id: fresh.id, label_key: "urgent").fingerprint
    stale = Label.where(record_id: old.map(&:id), label_key: "urgent")
    assert stale.none? { |label| label.fingerprint == fingerprint(:urgent) }
    assert_equal old.map(&:id).sort, Label.where(label_key: "urgent").where("value >= ?", 0.6).where(record_id: old.map(&:id)).pluck(:record_id).sort

    Backfill.new(Email).run

    assert_equal [ fingerprint(:urgent) ], Label.where(label_key: "urgent").distinct.pluck(:fingerprint)
    assert_equal [ version ], State.distinct.pluck(:vocabulary_version)
  end

  test "asks only the reworded question for stale records and leaves other labels untouched" do
    old = create_emails(2)
    perform_enqueued_jobs
    untouched = Label.where.not(label_key: "urgent").order(:id).pluck(:id, :value, :fingerprint, :labeled_at)
    reword_urgent
    @fake.calls.clear

    Backfill.new(Email).run

    assert_equal [ %w[r001__urgent r002__urgent] ], @fake.calls.map { |call| call[:questions].keys.sort }
    assert_equal untouched, Label.where.not(label_key: "urgent").order(:id).pluck(:id, :value, :fingerprint, :labeled_at)
    assert_equal old.size, Label.where(label_key: "urgent", fingerprint: fingerprint(:urgent)).count
  end

  test "asks at backfill priority" do
    create_emails(1)
    State.delete_all
    priorities = capture_notifications("truffler.jev_call") { Backfill.new(Email).run }.map { |payload| payload[:priority] }

    assert_equal [ :backfill ], priorities
  end

  test "stops with spend_cap_reached before exceeding the cap" do
    create_emails(6)
    State.delete_all
    cap = request_cost(2) * 2

    result = Backfill.new(Email, spend_cap: cap, batch_size: 2).run

    assert_equal :spend_cap_reached, result.status
    assert_equal 2, @fake.calls.size
    assert_equal 2, result.requests
    assert_operator result.cost, :<=, cap
    assert_equal 4, State.where(status: "labeled").count
  end

  def without_ledger_table
    Truffler::Records::BackfillSpend.instance_variable_set(:@missing_warned, nil)
    Truffler::Test::Schema.without_table("truffler_backfill_spends") { yield }
  ensure
    Truffler::Records::BackfillSpend.instance_variable_set(:@missing_warned, nil)
  end

  def hide_states(emails)
    State.where(record_id: emails.map(&:id)).delete_all
    clear_enqueued_jobs
  end

  test "0.1.2: backfill spend persists across runs, so a second run stops at the cap" do
    create_emails(2)
    State.delete_all
    cap = request_cost(2) * 2

    first = Backfill.new(Email, spend_cap: cap, batch_size: 2).run
    hide_states(create_emails(4))
    second = Backfill.new(Email, spend_cap: cap, batch_size: 2).run

    assert_equal [ :complete, 1 ], [ first.status, first.requests ]
    assert_equal [ :spend_cap_reached, 1 ], [ second.status, second.requests ]
    assert_equal 2, @fake.calls.size
    ledger = Backfill.spend(Email)
    assert_equal [ Email.polymorphic_name, 2 ], [ ledger.record_type, ledger.requests ]
    assert_in_delta cap, ledger.spent_usd, 1e-12
    assert_operator ledger.spent_usd, :<=, cap + 1e-12
  end

  test "0.1.2: overlapping backfill chains share one ledger and cannot spend past the cap together" do
    create_emails(10)
    State.delete_all
    cap = request_cost(2) * 3
    overlap = nil
    started = false
    nested = Class.new(Truffler::Clients::Fake) do
      define_method(:perform) do |**kwargs|
        unless started
          started = true
          overlap = Backfill.new(Email, spend_cap: cap, batch_size: 2, client: self).run
        end
        super(**kwargs)
      end
    end.new
    nested.answer(:needs_action, 0.8).answer(:urgent, 0.9)

    first = Backfill.new(Email, spend_cap: cap, batch_size: 2, client: nested).run

    assert_equal [ :spend_cap_reached, :spend_cap_reached ], [ first.status, overlap.status ]
    assert_equal 3, nested.calls.size
    assert_equal 3, first.requests + overlap.requests
    assert_equal 3, Backfill.spend(Email).requests
    assert_operator Backfill.spend(Email).spent_usd, :<=, cap + 1e-12
  end

  test "0.1.2: a vocabulary change starts a new ledger" do
    create_emails(2)
    State.delete_all
    cap = request_cost(2)
    Backfill.new(Email, spend_cap: cap).run
    old_version = Email.truffler_definition.vocabulary.version(all_users: true)
    reword_urgent

    result = Backfill.new(Email, spend_cap: cap).run

    assert_equal :complete, result.status
    ledgers = Truffler::Records::BackfillSpend.order(:id).pluck(:vocabulary_version, :requests)
    assert_equal [ [ old_version, 1 ], [ Email.truffler_definition.vocabulary.version(all_users: true), 1 ] ], ledgers
  end

  test "0.1.2: reset_spend! starts a fresh ledger for the current vocabulary" do
    create_emails(2)
    State.delete_all
    cap = request_cost(2)
    Backfill.new(Email, spend_cap: cap).run
    hide_states(create_emails(2))
    assert_equal :spend_cap_reached, Backfill.new(Email, spend_cap: cap).run.status

    Backfill.reset_spend!(Email)

    assert_equal [ 0.0, 0 ], [ Backfill.spend(Email).spent_usd, Backfill.spend(Email).requests ]
    assert_equal :complete, Backfill.new(Email, spend_cap: cap).run.status
  end

  test "0.1.2: without the ledger table a run warns once and meters spend per run, counting spend carried in" do
    create_emails(4)
    State.delete_all
    cost = request_cost(2)
    log = StringIO.new
    Truffler.config.logger = ActiveSupport::Logger.new(log)

    without_ledger_table do
      carried = Backfill.new(Email, spend_cap: cost * 2, spent: cost, batch_size: 2).run
      again = Backfill.new(Email, spend_cap: cost * 2, batch_size: 2).run

      assert_equal [ :spend_cap_reached, :complete ], [ carried.status, again.status ]
      assert_nil Backfill.spend(Email)
    end

    assert_equal 1, log.string.scan("truffler_backfill_spends").size
    assert_match(/truffler:upgrade/, log.string)
  end

  test "an interrupted run and a second run label each record exactly once" do
    create_emails(6)
    State.delete_all
    flaky = FlakyClient.new(succeed: 1)
    Truffler.config.client = flaky

    assert_equal :client_error, Backfill.new(Email, batch_size: 2).run.status
    assert_equal 2, State.where(status: "labeled").count

    Truffler.config.client = @fake
    result = Backfill.new(Email, batch_size: 2).run

    assert_equal :complete, result.status
    assert_equal 4, labeled_tags
    assert_equal 6, State.where(status: "labeled").count
    assert_equal 6, Label.where(label_key: "urgent").count
  end

  test "a second run over current records makes no Jev calls" do
    create_emails(3)
    perform_enqueued_jobs
    @fake.calls.clear

    result = Backfill.new(Email).run

    assert_equal [ :complete, 0 ], [ result.status, @fake.calls.size ]
  end

  test "picks up failed rows and rows demoted to backfill priority, never live pending rows" do
    failed, demoted, live = create_emails(3)
    clear_enqueued_jobs
    State.where(record_id: failed.id).update_all(status: "failed", attempts: 5, last_error_class: "Truffler::ClientError")
    State.where(record_id: demoted.id).update_all(priority: "backfill")

    Backfill.new(Email).run

    assert_equal [ "labeled", 0, nil ], State.find_by!(record_id: failed.id).then { |s| [ s.status, s.attempts, s.last_error_class ] }
    assert_equal "labeled", State.find_by!(record_id: demoted.id).status
    assert_equal [ "pending", "live" ], State.find_by!(record_id: live.id).then { |s| [ s.status, s.priority ] }
  end

  test "a budget denial releases claimed rows and reports the cursor to resume from" do
    create_emails(4)
    State.delete_all
    budget = Truffler::Budget.new
    denied = Truffler::Budget::Decision.new(:denied, :backfill, :exhausted)
    granted = Truffler::Budget::Decision.new(:granted, :backfill, nil)
    decisions = [ granted, denied ]
    budget.define_singleton_method(:acquire) { |**| decisions.shift || denied }

    result = Backfill.new(Email, batch_size: 2, page_size: 2, budget: budget).run

    assert_equal :budget_denied, result.status
    newest_two = Email.order(id: :desc).limit(2).pluck(:id)
    assert_equal newest_two.min, result.cursor
    assert_equal [ [ "pending", "backfill" ] ] * 2, State.where.not(record_id: newest_two).pluck(:status, :priority)
  end

  # Advances only when the backfill sleeps, so waiting tests never sleep.
  class FakeClock
    attr_reader :now, :sleeps

    def initialize
      @now = 0.0
      @sleeps = []
    end

    def call
      now
    end

    def sleep(seconds)
      @sleeps << seconds
      @now += seconds
    end
  end

  def scripted_budget(*outcomes)
    budget = Truffler::Budget.new
    decisions = outcomes.map do |outcome, retry_after|
      Truffler::Budget::Decision.new(outcome: outcome, priority: :backfill, reason: (:exhausted if outcome == :denied),
        retry_after: retry_after)
    end
    budget.define_singleton_method(:acquire) { |**| decisions.shift || Truffler::Budget::Decision.new(:granted, :backfill, nil) }
    budget
  end

  def always_denied_budget
    budget = Truffler::Budget.new
    budget.define_singleton_method(:acquire) { |**| Truffler::Budget::Decision.new(:denied, :backfill, :exhausted) }
    budget
  end

  test "0.1.2: waiting mode backs off on budget denials and resumes from the same cursor until complete" do
    create_emails(4)
    State.delete_all
    clock = FakeClock.new
    budget = scripted_budget([ :granted ], [ :denied ], [ :denied ], [ :denied ])

    result = Backfill.new(Email, batch_size: 2, page_size: 2, budget: budget)
      .run(wait: true, sleeper: clock.method(:sleep), clock: clock)

    assert_equal [ :complete, 4, 2, nil ], [ result.status, result.labeled, result.requests, result.cursor ]
    assert_equal [ 1.0, 2.0, 4.0 ], clock.sleeps
    assert_equal [ "labeled" ] * 4, State.pluck(:status)
    assert_equal 2, @fake.calls.size
  end

  test "0.1.2: backoff starts at 1 s, doubles, caps at 30 s, and honors a longer retry hint" do
    assert_equal [ 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0 ], (0..6).map { |denials| Backfill.backoff(denials) }
    assert_equal 5.0, Backfill.backoff(0, 5.0)
    assert_equal 4.0, Backfill.backoff(2, 0.2)
  end

  test "0.1.2: waiting mode waits at least the budget's retry hint" do
    create_emails(2)
    State.delete_all
    clock = FakeClock.new

    result = Backfill.new(Email, batch_size: 2, budget: scripted_budget([ :denied, 3.0 ]))
      .run(wait: true, sleeper: clock.method(:sleep), clock: clock)

    assert_equal :complete, result.status
    assert_equal [ 3.0 ], clock.sleeps
  end

  test "0.1.2: max_duration stops a waiting backfill with :paused and the cursor to resume from" do
    emails = create_emails(4)
    State.delete_all
    clock = FakeClock.new
    budget = scripted_budget([ :granted ], *Array.new(10) { [ :denied ] })

    result = Backfill.new(Email, batch_size: 2, page_size: 2, budget: budget)
      .run(wait: true, max_duration: 10, sleeper: clock.method(:sleep), clock: clock)

    assert_equal [ :paused, emails[2].id, 2 ], [ result.status, result.cursor, result.labeled ]
    assert_equal [ 1.0, 2.0, 4.0 ], clock.sleeps
    assert_equal [ [ "pending", "backfill" ] ] * 2, State.where(record_id: emails.first(2).map(&:id)).pluck(:status, :priority)
  end

  test "0.1.2: waiting mode reports progress before each wait without record text" do
    create_emails(2)
    State.delete_all
    clock = FakeClock.new
    reports = []

    Backfill.new(Email, batch_size: 2, budget: scripted_budget([ :denied ]))
      .run(wait: true, sleeper: clock.method(:sleep), clock: clock, progress: ->(result, delay) { reports << [ result, delay ] })

    assert_equal 1, reports.size
    result, delay = reports.sole
    assert_equal [ :budget_denied, 0, 1.0 ], [ result.status, result.labeled, delay ]
    assert_equal %i[status labeled requests cost cursor retry_after], result.to_h.keys
  end

  test "0.1.2: without wait a denial still ends the run with :budget_denied" do
    create_emails(2)
    State.delete_all

    assert_equal :budget_denied, Backfill.new(Email, budget: always_denied_budget).run.status
  end

  test "resumes below a cursor" do
    emails = create_emails(4)
    State.delete_all

    Backfill.new(Email, cursor: emails[2].id).run

    assert_equal emails.first(2).map(&:id).sort, State.pluck(:record_id).sort
  end

  test "keeps tenants in separate requests" do
    create_emails(2, account_id: 1)
    create_emails(2, account_id: 2)
    State.delete_all

    Backfill.new(Email).run

    assert_equal 2, @fake.calls.size
    assert_equal [ %w[1 1], %w[2 2] ], State.order(:tenant_key).pluck(:tenant_key).each_slice(2).to_a
  end

  test "with a per-tenant vocabulary relabels only the tenant whose options changed" do
    options = { "1" => %w[billing other], "2" => %w[billing other] }
    per_tenant = @original.dup
    category = Truffler::LabelDefinition.new(:category, :choice, question: "Which category?", options: ->(tenant) { options[tenant] })
    per_tenant.instance_variable_set(:@labels, @original.labels.merge("category" => category))
    Email.truffler_definition = per_tenant
    create_emails(2, account_id: 1)
    create_emails(2, account_id: 2)
    perform_enqueued_jobs
    options["2"] = %w[billing travel other]
    @fake.calls.clear

    Backfill.new(Email).run

    assert_equal %w[r001__category r002__category], @fake.calls.sole[:questions].keys.sort
    assert_equal [ version("1"), version("1"), version("2"), version("2") ], State.order(:tenant_key).pluck(:vocabulary_version)
  end

  test "pauses after max_pages with a cursor for the next run" do
    emails = create_emails(4)
    State.delete_all

    result = Backfill.new(Email, batch_size: 2, page_size: 2).run(max_pages: 1)

    assert_equal [ :paused, emails[2].id ], [ result.status, result.cursor ]
    assert_equal 2, State.count
  end

  test "status counts records by status and staleness" do
    create_emails(4)
    perform_enqueued_jobs
    Email.create!(account_id: 1, subject: "Queued", body: "later", sender_name: "Bo")
    Truffler::Records::RecordState.where(record_id: Email.first.id).update_all(status: "failed")
    State.where(record_id: Email.second.id).delete_all
    reword_urgent

    status = Backfill.status(Email)

    assert_equal({ total: 5, missing: 1, pending: 1, labeling: 0, labeled: 2, failed: 1, stale: 2, current: 0 }, status)
  end
end
