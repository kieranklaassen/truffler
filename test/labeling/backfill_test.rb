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

  test "a spend cap counts spend already carried in from earlier runs" do
    create_emails(4)
    State.delete_all
    cost = request_cost(2)

    result = Backfill.new(Email, spend_cap: cost * 2, spent: cost, batch_size: 2).run

    assert_equal [ :spend_cap_reached, 1 ], [ result.status, @fake.calls.size ]
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
