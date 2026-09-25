require "test_helper"

class ResumeJobTest < Truffler::TestCase
  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState
  ResumeJob = Truffler::Jobs::ResumeJob

  setup do
    @fake = Truffler::Clients::Fake.new
    Truffler.config.client = @fake
  end

  def create_email(account_id: 1)
    Email.create!(account_id: account_id, subject: "Invoice", body: "Pay it", sender_name: "Ann")
  end

  test "moves failed rows back to pending and the next flush labels them once Jev recovers" do
    Truffler.config.max_attempts = 1
    email = create_email
    @fake.fail_with(Truffler::Test::HttpError.new(503, "Service Unavailable"))
    perform_enqueued_jobs
    assert_equal "failed", State.sole.status
    clear_enqueued_jobs
    @fake.fail_with(nil)

    ResumeJob.perform_now

    assert_equal [ "pending", 0 ], State.pluck(:status, :attempts).sole
    assert_enqueued_jobs 1, only: Truffler::Jobs::LabelFlushJob
    perform_enqueued_jobs
    assert_equal "labeled", State.sole.status
    assert_equal 4, Label.where(record_id: email.id).count
  end

  test "reschedules a flush for pending live rows older than the threshold" do
    create_email
    clear_enqueued_jobs
    State.update_all(updated_at: 10.minutes.ago)

    ResumeJob.perform_now

    assert_enqueued_with(job: Truffler::Jobs::LabelFlushJob, args: [ "Email", "1" ])
  end

  test "leaves fresh pending rows to their scheduled flush" do
    create_email
    clear_enqueued_jobs

    ResumeJob.perform_now

    assert_no_enqueued_jobs
  end

  test "releases rows stuck in labeling after a crashed worker" do
    create_email
    clear_enqueued_jobs
    State.update_all(status: "labeling", claimed_at: 10.minutes.ago)

    ResumeJob.perform_now

    assert_equal [ "pending", nil ], State.pluck(:status, :claimed_at).sole
    assert_enqueued_jobs 1, only: Truffler::Jobs::LabelFlushJob
  end

  test "enqueues a backfill for rows waiting at backfill priority" do
    create_email
    clear_enqueued_jobs
    State.update_all(priority: "backfill", updated_at: 10.minutes.ago)

    ResumeJob.perform_now

    assert_enqueued_with(job: Truffler::Jobs::BackfillJob, args: [ "Email", { tenant_key: "1" } ])
    assert_no_enqueued_jobs only: Truffler::Jobs::LabelFlushJob
  end

  test "sweeps one model when given its type" do
    create_email
    clear_enqueued_jobs
    State.update_all(status: "failed")

    ResumeJob.perform_now("SecretNote")

    assert_equal "failed", State.sole.status
  end
end
