require "test_helper"
require "minitest/mock"

class BackfillJobTest < Truffler::TestCase
  State = Truffler::Records::RecordState
  BackfillJob = Truffler::Jobs::BackfillJob

  # Each successful request reports one million input tokens, so it costs
  # exactly `cost_per_million_tokens`; the listed call numbers fail with a 503.
  class MeteredFlakyClient < Truffler::Clients::Fake
    attr_reader :paid

    def initialize(fail_on:)
      super()
      @fail_on = fail_on
      @paid = 0
    end

    def perform(**)
      response = super
      raise Truffler::Test::HttpError.new(503, "Service Unavailable") if @fail_on.include?(calls.size)

      @paid += 1
      response.merge("usage" => { "input_tokens" => 1_000_000 })
    end
  end

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

  test "0.1.1: BackfillJob is capped by default, and a nil backfill_spend_cap disables the cap" do
    create_emails(2)
    Truffler.config.cost_per_million_tokens = 100_000_000.0

    capped = capture_notifications("truffler.backfill") { BackfillJob.perform_now("Email") }
    Truffler.config.backfill_spend_cap = nil
    uncapped = capture_notifications("truffler.backfill") { BackfillJob.perform_now("Email") }

    assert_equal [ :spend_cap_reached ], capped.map { |payload| payload[:outcome] }
    assert_equal [ :complete ], uncapped.map { |payload| payload[:outcome] }
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

    payloads = capture_notifications("truffler.backfill") { BackfillJob.perform_now("Email") }

    assert_equal [ [ "pending", "backfill", 1 ] ], State.pluck(:status, :priority, :attempts)
    assert_equal [ :client_error ], payloads.map { |payload| payload[:outcome] }
    job = enqueued_jobs.sole
    assert job[:at], "the retry waits before asking Jev again"
    assert_equal 1, ActiveJob::Arguments.deserialize(job[:args]).last[:attempt]
  end

  test "a retry after a Jev error carries the spend made before the error" do
    create_emails(6)
    Truffler.config.batch_size = 2
    Truffler.config.client = MeteredFlakyClient.new(fail_on: [ 3 ])
    price = Truffler.config.cost_per_million_tokens

    BackfillJob.perform_now("Email")

    arguments = ActiveJob::Arguments.deserialize(enqueued_jobs.sole[:args]).last
    assert_equal 4, State.where(status: "labeled").count
    assert_in_delta 2 * price, arguments[:spent], 1e-12
    assert_equal 1, arguments[:attempt]
  end

  test "the spend cap holds across retries" do
    create_emails(10)
    Truffler.config.batch_size = 2
    client = MeteredFlakyClient.new(fail_on: [ 3 ])
    Truffler.config.client = client
    price = Truffler.config.cost_per_million_tokens

    BackfillJob.perform_now("Email", spend_cap: 2.5 * price)
    drain_jobs

    assert_equal 3, client.paid, "the retry resumes from the spend already made"
    assert_equal 6, State.where(status: "labeled").count
  end

  test "gives up after the last retry and leaves rows pending for the resume sweep" do
    create_emails(1)
    @fake.fail_with(Truffler::Test::HttpError.new(503, "Service Unavailable"))

    BackfillJob.perform_now("Email", attempt: BackfillJob::MAX_ATTEMPTS - 1)

    assert_no_enqueued_jobs only: BackfillJob
    assert_equal [ "pending" ], State.pluck(:status)
  end

  test "a model that is not declared does nothing" do
    assert_nothing_raised { BackfillJob.perform_now("NoSuchModel") }
  end
end
