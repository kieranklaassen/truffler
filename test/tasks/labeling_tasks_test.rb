require "test_helper"
require "rake"

class LabelingTasksTest < Truffler::TestCase
  State = Truffler::Records::RecordState

  setup do
    @rake = Rake::Application.new
    Rake.application = @rake
    load File.expand_path("../../lib/tasks/truffler.rake", __dir__)
    @fake = Truffler::Clients::Fake.new
    Truffler.config.client = @fake
  end

  teardown do
    Rake.application = Rake::Application.new
  end

  def create_emails(count)
    Array.new(count) { Email.create!(account_id: 1, subject: "Invoice", body: "Pay it", sender_name: "Ann") }
  end

  test "status prints counts by status and staleness" do
    create_emails(2)
    perform_enqueued_jobs
    create_emails(1)

    output, = capture_io { @rake["truffler:status"].invoke("Email") }

    assert_includes output, "Email"
    assert_match(/total\s+3/, output)
    assert_match(/labeled\s+2/, output)
    assert_match(/pending\s+1/, output)
    assert_match(/stale\s+0/, output)
  end

  test "backfill labels the model inline and prints the outcome" do
    create_emails(2)
    State.delete_all
    clear_enqueued_jobs

    output, = capture_io { @rake["truffler:backfill"].invoke("Email") }

    assert_equal [ "labeled" ] * 2, State.pluck(:status)
    assert_match(/complete/, output)
  end

  test "an unknown model aborts with a message" do
    _, error = capture_io do
      assert_raises(SystemExit) { @rake["truffler:status"].invoke("Nope") }
    end

    assert_match(/Nope is not a Truffler model/, error)
  end
end
