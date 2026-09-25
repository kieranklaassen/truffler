require "test_helper"
require "minitest/mock"

class BackfillJobTest < Truffler::TestCase
  State = Truffler::Records::RecordState
  BackfillJob = Truffler::Jobs::BackfillJob

  setup do
    @fake = Truffler::Clients::Fake.new
    Truffler.config.client = @fake
  end

  def create_emails(count, account_id: 1)
    emails = Array.new(count) { Email.create!(account_id: account_id, subject: "Invoice", body: "Pay it", sender_name: "Ann") }
    State.delete_all
    clear_enqueued_jobs
    emails
  end

  def deny_after(granted)
    budget = Truffler::Budget.new
    decisions = [ Truffler::Budget::Decision.new(:granted, :backfill, nil) ] * granted
    budget.define_singleton_method(:acquire) { |**| decisions.shift || Truffler::Budget::Decision.new(:denied, :backfill, :exhausted) }
    budget
  end

  test "labels every stale record of the model" do
    create_emails(3)

    BackfillJob.perform_now("Email")

    assert_equal [ "labeled" ] * 3, State.pluck(:status)
    assert_no_enqueued_jobs only: BackfillJob
  end

  test "job arguments carry no record text" do
    create_emails(1)

    BackfillJob.perform_later("Email")

    assert_equal [ "Email" ], enqueued_jobs.sole[:args]
  end

  test "a budget denial reschedules the job with the next cursor and the spend so far" do
    emails = create_emails(12)
    Truffler.config.batch_size = 2
    Truffler::Budget.stub(:new, deny_after(5)) do
      BackfillJob.perform_now("Email")
    end

    job = enqueued_jobs.sole
    assert_equal BackfillJob, job[:job]
    arguments = ActiveJob::Arguments.deserialize(job[:args])
    assert_equal "Email", arguments.first
    assert_equal emails[2].id, arguments.last[:cursor]
    assert_operator arguments.last[:spent], :>, 0
    assert job[:at], "the rescheduled job waits for budget"
  end

  test "the rescheduled job finishes the backfill once budget returns" do
    create_emails(4)
    Truffler.config.batch_size = 2
    Truffler::Budget.stub(:new, deny_after(1)) { BackfillJob.perform_now("Email") }

    perform_enqueued_jobs

    assert_equal [ "labeled" ] * 4, State.pluck(:status)
    assert_equal 2, @fake.calls.size
  end

  test "stops at the spend cap without rescheduling and reports the outcome" do
    create_emails(4)
    Truffler.config.batch_size = 2
    Truffler.config.backfill_spend_cap = 0.0

    payloads = capture_notifications("truffler.backfill") { BackfillJob.perform_now("Email") }

    assert_empty @fake.calls
    assert_no_enqueued_jobs only: BackfillJob
    assert_equal [ { record_type: "Email", outcome: :spend_cap_reached, labeled_count: 0, request_count: 0, cost: 0.0 } ], payloads
  end

  test "continues in a follow-up job after max_pages" do
    create_emails(6)
    Truffler.config.batch_size = 1

    BackfillJob.perform_now("Email", max_pages: 1)

    assert_equal 5, State.where(status: "labeled").count
    assert_enqueued_jobs 1, only: BackfillJob
    drain_jobs
    assert_equal 6, State.where(status: "labeled").count
  end

  test "picks up rows the flush job demoted over the tenant cap" do
    Truffler.config.tenant_live_cap = 2
    3.times { Email.create!(account_id: 1, subject: "Invoice", body: "Pay it", sender_name: "Ann") }
    perform_enqueued_jobs
    assert_equal [ [ "pending", "backfill" ] ] * 3, State.pluck(:status, :priority)

    BackfillJob.perform_now("Email")

    assert_equal [ "labeled" ] * 3, State.pluck(:status)
  end

  test "a Jev outage releases rows and retries the job" do
    create_emails(1)
    @fake.fail_with(Truffler::Test::HttpError.new(503, "Service Unavailable"))

    BackfillJob.perform_now("Email")

    assert_equal [ [ "pending", "backfill", 1 ] ], State.pluck(:status, :priority, :attempts)
    assert_enqueued_jobs 1, only: BackfillJob
  end

  test "a model that is not declared does nothing" do
    assert_nothing_raised { BackfillJob.perform_now("NoSuchModel") }
  end
end
