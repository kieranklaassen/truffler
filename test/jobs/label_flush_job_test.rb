require "test_helper"

class LabelFlushJobTest < Truffler::TestCase
  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState

  setup do
    @fake = Truffler::Clients::Fake.new
    Truffler.config.client = @fake
  end

  def create_email(account_id: 1, body: "Pay invoice 4471")
    Email.create!(account_id: account_id, subject: "Invoice", body: body, sender_name: "Ann")
  end

  test "labels a created record through the enqueued job" do
    email = create_email

    perform_enqueued_jobs

    assert_equal 6, Label.where(record_id: email.id).count
    assert_equal "labeled", State.sole.status
  end

  test "records created within the grouping window share one request" do
    Truffler.config.grouping_window = 2.seconds
    3.times { create_email }

    perform_enqueued_jobs

    assert_equal 1, @fake.calls.size
    assert_equal %w[r001 r002 r003], @fake.calls.sole[:state]["records"].keys
  end

  test "two tenants never share a request" do
    create_email(account_id: 1, body: "tenant one")
    create_email(account_id: 2, body: "tenant two")

    perform_enqueued_jobs

    assert_equal 2, @fake.calls.size
    @fake.calls.each { |call| assert_equal 1, call[:state]["records"].size }
  end

  test "a batch larger than batch_size flushes in follow-up jobs" do
    Truffler.config.batch_size = 2
    5.times { create_email }

    drain_jobs

    assert_equal 3, @fake.calls.size
    assert State.all.all? { |state| state.status == "labeled" }
  end

  test "a Jev outage returns rows to pending and leaves the record readable" do
    email = create_email
    clear_enqueued_jobs
    @fake.fail_with(Truffler::Test::HttpError.new(503, "Service Unavailable"))

    Truffler::Jobs::LabelFlushJob.perform_now("Email", "1")

    assert_equal [ "pending", 1 ], State.pluck(:status, :attempts).sole
    assert_equal 0, Label.count
    assert_equal "Pay invoice 4471", Email.find(email.id).body
    assert_enqueued_jobs 1, only: Truffler::Jobs::LabelFlushJob
  end

  test "after max_attempts failures the rows are failed with the error class only" do
    Truffler.config.max_attempts = 2
    create_email
    clear_enqueued_jobs
    @fake.fail_with(Truffler::Test::HttpError.new(500, "boom: Pay invoice 4471"))

    2.times { Truffler::Jobs::LabelFlushJob.perform_now("Email", "1") }

    state = State.sole
    assert_equal [ "failed", 2, "Truffler::ClientError" ], [ state.status, state.attempts, state.last_error_class ]
  end

  test "a tenant over its live cap drops to backfill priority and stays pending" do
    Truffler.config.tenant_live_cap = 2
    3.times { create_email }

    perform_enqueued_jobs

    assert_empty @fake.calls
    assert_equal [ [ "pending", "backfill" ] ] * 3, State.pluck(:status, :priority)
  end

  test "demoting over-cap rows schedules one delayed backfill" do
    Truffler.config.tenant_live_cap = 2
    3.times { create_email }
    3.times { create_email(account_id: 2) }
    clear_enqueued_jobs

    freeze_time do
      Truffler::Jobs::LabelFlushJob.perform_now("Email", "1")
      Truffler::Jobs::LabelFlushJob.perform_now("Email", "2")

      backfill = enqueued_jobs.select { |job| job[:job] == Truffler::Jobs::BackfillJob }
      assert_equal 1, backfill.size, "the marker deduplicates the backfill"
      assert_equal [ "Email" ], backfill.sole[:args]
      assert_in_delta 1.minute.from_now.to_f, backfill.sole[:at], 1
    end

    clear_enqueued_jobs
    perform_enqueued_jobs { Truffler::Jobs::BackfillJob.perform_now("Email") }
    assert_equal [ "labeled" ] * 6, State.pluck(:status)
  end

  test "a job for a model that is no longer declared does nothing" do
    assert_nothing_raised { Truffler::Jobs::LabelFlushJob.perform_now("Email", "missing-tenant") }
    assert_empty @fake.calls
  end
end
