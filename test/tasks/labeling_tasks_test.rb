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

  def with_spend_cap_env(value)
    previous = ENV.fetch("SPEND_CAP", nil)
    ENV["SPEND_CAP"] = value
    yield
  ensure
    ENV["SPEND_CAP"] = previous
  end

  test "0.1.1: backfill without SPEND_CAP stops at the default cap; SPEND_CAP=none lifts it" do
    create_emails(2)
    State.delete_all
    clear_enqueued_jobs
    Truffler.config.cost_per_million_tokens = 100_000_000.0

    capped, = with_spend_cap_env(nil) { capture_io { @rake["truffler:backfill"].invoke("Email") } }
    @rake["truffler:backfill"].reenable
    uncapped, = with_spend_cap_env("none") { capture_io { @rake["truffler:backfill"].invoke("Email") } }

    assert_match(/spend_cap_reached, 0 labeled/, capped)
    assert_match(/complete, 2 labeled/, uncapped)
  end

  test "0.1.1: a SPEND_CAP that is neither dollars nor none aborts" do
    _, error = with_spend_cap_env("lots") do
      capture_io { assert_raises(SystemExit) { @rake["truffler:backfill"].invoke("Email") } }
    end

    assert_match(/SPEND_CAP/, error)
  end

  test "an unknown model aborts with a message" do
    _, error = capture_io do
      assert_raises(SystemExit) { @rake["truffler:status"].invoke("Nope") }
    end

    assert_match(/Nope is not a Truffler model/, error)
  end
end
