require "test_helper"
require "rake"
require "minitest/mock"

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

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def with_sleeps
    sleeps = []
    now = 0.0
    backfill = Truffler::Labeling::Backfill
    original = [ backfill.sleeper, backfill.clock ]
    backfill.sleeper = lambda do |seconds|
      sleeps << seconds
      now += seconds
    end
    backfill.clock = -> { now }
    yield sleeps
  ensure
    backfill.sleeper, backfill.clock = original
  end

  def budget_denying(times, after: 0)
    budget = Truffler::Budget.new
    decisions = [ Truffler::Budget::Decision.new(:granted, :backfill, nil) ] * after +
      [ Truffler::Budget::Decision.new(:denied, :backfill, :exhausted) ] * times
    budget.define_singleton_method(:acquire) { |**| decisions.shift || Truffler::Budget::Decision.new(:granted, :backfill, nil) }
    budget
  end

  test "0.1.2: backfill waits through budget denials by default and prints progress without record text" do
    create_emails(2)
    State.delete_all
    clear_enqueued_jobs

    output = nil
    sleeps = with_sleeps do |slept|
      Truffler::Budget.stub(:new, budget_denying(2)) { output, = capture_io { @rake["truffler:backfill"].invoke("Email") } }
      slept
    end

    assert_equal [ 1.0, 2.0 ], sleeps
    assert_equal [ "labeled" ] * 2, State.pluck(:status)
    assert_match(/Email: complete, 2 labeled/, output)
    assert_match(/waiting 1\.0s for backfill budget \(0 labeled, \$0\.000000 spent, cursor none\)/, output)
    assert_no_match(/Invoice|Pay it|Ann/, output)
  end

  test "0.1.2: MAX_DURATION stops a waiting backfill with paused and the cursor" do
    emails = create_emails(12)
    State.delete_all
    clear_enqueued_jobs
    Truffler.config.batch_size = 2

    output = nil
    with_sleeps do
      with_env("MAX_DURATION" => "5") do
        Truffler::Budget.stub(:new, budget_denying(50, after: 5)) do
          output, = capture_io { @rake["truffler:backfill"].invoke("Email") }
        end
      end
    end

    assert_match(/Email: paused, 10 labeled in 5 requests, \$\d+\.\d{6}, cursor #{emails[2].id}/, output)
  end

  test "0.1.2: a MAX_DURATION that is not a number of seconds aborts" do
    _, error = with_env("MAX_DURATION" => "soon") do
      capture_io { assert_raises(SystemExit) { @rake["truffler:backfill"].invoke("Email") } }
    end

    assert_match(/MAX_DURATION/, error)
  end

  def request_cost
    records = Email.order(:id).first(2).map { |email| [ email, Email.truffler_definition.label_keys ] }
    request = Truffler::Labeling::RequestBuilder.new(Email.truffler_definition, tenant_key: "1").build(records).sole
    Truffler.config.cost_for(Truffler::Tokens.estimate({ state: request.state, questions: request.questions }))
  end

  def fresh_emails(count)
    emails = create_emails(count)
    State.where(record_id: emails.map(&:id)).delete_all
    clear_enqueued_jobs
    emails
  end

  test "0.1.2: rerunning backfill stops at the cap spent by the earlier run; RESET_SPEND=1 starts a fresh ledger" do
    fresh_emails(2)
    cap = format("%.12f", request_cost * 1.5)

    first, = with_env("SPEND_CAP" => cap) { capture_io { @rake["truffler:backfill"].invoke("Email") } }
    fresh_emails(2)
    @rake["truffler:backfill"].reenable
    capped, = with_env("SPEND_CAP" => cap) { capture_io { @rake["truffler:backfill"].invoke("Email") } }
    @rake["truffler:backfill"].reenable
    reset, = with_env("SPEND_CAP" => cap, "RESET_SPEND" => "1") { capture_io { @rake["truffler:backfill"].invoke("Email") } }

    assert_match(/complete, 2 labeled in 1 requests/, first)
    assert_match(/spend_cap_reached, 0 labeled in 0 requests/, capped)
    assert_match(/fresh spend ledger/, reset)
    assert_match(/complete, 2 labeled in 1 requests/, reset)
    assert_equal 2, @fake.calls.size
  end

  test "0.1.2: status prints the spend recorded for the current vocabulary version" do
    fresh_emails(2)
    capture_io { @rake["truffler:backfill"].invoke("Email") }

    output, = capture_io { @rake["truffler:status"].invoke("Email") }

    version = Email.truffler_definition.vocabulary.version(all_users: true)
    assert_match(/spent\s+\$\d+\.\d{6} in 1 requests \(vocabulary #{version.first(12)}, cap \$5\.00\)/, output)
  end

  test "0.1.2: status without the ledger table says spend is per run and how to upgrade" do
    output, = Truffler::Test::Schema.without_table("truffler_backfill_spends") do
      capture_io { @rake["truffler:status"].invoke("Email") }
    end

    assert_match(/spent\s+not tracked across runs; run bin\/rails g truffler:upgrade/, output)
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
