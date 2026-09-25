require "test_helper"

class QueueTest < Truffler::TestCase
  State = Truffler::Records::RecordState

  def create_email(**attributes)
    Email.create!({ account_id: 1, subject: "Invoice", body: "Pay by Friday", sender_name: "Ann" }.merge(attributes))
  end

  test "creating a record upserts a pending live state and enqueues one flush job with ids only" do
    email = create_email

    state = State.find_by!(record_type: "Email", record_id: email.id)
    assert_equal [ "pending", "live", "1", 0 ], [ state.status, state.priority, state.tenant_key, state.attempts ]
    assert_enqueued_with(job: Truffler::Jobs::LabelFlushJob, args: [ "Email", "1" ])
  end

  test "records of one tenant share a pending flush job until it runs" do
    3.times { create_email }
    create_email(account_id: 2)

    assert_enqueued_jobs 2, only: Truffler::Jobs::LabelFlushJob
  end

  test "the grouping window delays the flush job" do
    Truffler.config.grouping_window = 2.seconds

    freeze_time do
      create_email
      assert_enqueued_with(job: Truffler::Jobs::LabelFlushJob, at: 2.seconds.from_now)
    end
  end

  test "updating a read field re-queues the record; other fields do not" do
    email = create_email
    State.update_all(status: "labeled")
    clear_enqueued_jobs
    Truffler.config.cache_store.clear

    email.update!(received_at: Time.current)
    assert_no_enqueued_jobs
    assert_equal "labeled", State.sole.status

    email.update!(body: "Actually, no rush")
    assert_equal "pending", State.sole.status
    assert_enqueued_jobs 1
  end

  test "claim takes pending rows of one tenant and priority up to the limit" do
    3.times { create_email }
    create_email(account_id: 2)
    queue = Truffler::Labeling::Queue.new(Email)

    claimed = queue.claim("1", priority: :live, limit: 2)

    assert_equal 2, claimed.size
    assert claimed.all? { |state| state.status == "labeling" && state.tenant_key == "1" }
    assert_equal 1, queue.claim("1", priority: :live, limit: 5).size
    assert_empty queue.claim("1", priority: :live, limit: 5)
  end

  test "release returns rows to pending and fails them after max attempts" do
    Truffler.config.max_attempts = 2
    create_email
    queue = Truffler::Labeling::Queue.new(Email)

    queue.release(queue.claim("1", priority: :live, limit: 5), Truffler::ClientError.new(status: 503))
    assert_equal [ "pending", 1, "Truffler::ClientError" ], State.pluck(:status, :attempts, :last_error_class).sole

    queue.release(queue.claim("1", priority: :live, limit: 5), Truffler::ClientError.new(status: 503))
    assert_equal [ "failed", 2, "Truffler::ClientError" ], State.pluck(:status, :attempts, :last_error_class).sole
  end

  test "demote moves rows to backfill priority and leaves them pending" do
    create_email
    queue = Truffler::Labeling::Queue.new(Email)

    queue.demote(queue.claim("1", priority: :live, limit: 5))

    assert_equal [ "pending", "backfill" ], State.pluck(:status, :priority).sole
  end

  test "destroying a record forgets its state and labels" do
    email = create_email
    Truffler::Records::Label.create!(record_type: "Email", record_id: email.id, tenant_key: "1", label_key: "urgent",
      value: 0.4, fingerprint: "x", labeled_at: Time.current)

    email.destroy!

    assert_equal 0, State.count
    assert_equal 0, Truffler::Records::Label.count
  end
end
