require "test_helper"

class ProviderSearchJobTest < Truffler::TestCase
  FakeGmail = Truffler::Test::FakeGmail
  FakeRun = Truffler::Test::FakeRun
  Job = Truffler::Jobs::ProviderSearchJob

  setup do
    @run_finder = Truffler::Providers.run_finder
    Truffler::Providers.run_finder = ->(id) { FakeRun.find(id) }
    FakeGmail.current = FakeGmail.new("1" => [ { id: "g-1", subject: "Invoice 4471" } ],
      "2" => [ { id: "g-2", subject: "Invoice 4471 for account two" } ])
  end

  teardown do
    Truffler::Providers.run_finder = @run_finder
    FakeRun.clear
    FakeGmail.current = nil
  end

  def run_for(query = "invoice 4471", **options)
    FakeRun.new(model: GmailEmail, query: query, sections: { smart: { status: :pending } }, **options)
  end

  test "stores the provider's results with its label and pings once" do
    run = run_for

    Job.perform_now(run.id, "1", "user-1")

    assert_equal [ [ :provider, { status: :results, name: "gmail", label: "Gmail", results: [ { id: "g-1", subject: "Invoice 4471" } ] } ] ],
      run.updates
    assert_equal({ status: :pending }, run.sections[:smart])
  end

  test "the provider returning nothing stores empty" do
    run = run_for("nothing matches this")

    Job.perform_now(run.id, "1", "user-1")

    assert_equal({ status: :empty, name: "gmail", label: "Gmail" }, run.sections[:provider])
  end

  test "a raising provider stores unavailable with the error class only, and local sections still stand" do
    FakeGmail.current.error = RuntimeError.new("token for kieran@example.test expired: invoice 4471")
    run = run_for

    payloads = capture_notifications("truffler.provider_search") { Job.perform_now(run.id, "1", "user-1") }

    assert_equal({ status: :unavailable, name: "gmail", label: "Gmail", error_class: "RuntimeError" }, run.sections[:provider])
    assert_equal({ status: :pending }, run.sections[:smart])
    assert_equal 1, run.updates.size
    assert_not_includes (run.sections.to_s + payloads.to_json), "expired"
  end

  test "the provider is called with the run's query and the searching user's tenant and user keys" do
    run = run_for(Truffler::Search::Query.new("  Invoice 4471 "), tenant_key: "2", user_key: "user-9")

    Job.perform_now(run.id, "2", "user-9")

    assert_equal [ { query: "Invoice 4471", tenant: "2", user: "user-9" } ], FakeGmail.current.calls
    assert_equal [ "g-2" ], run.sections[:provider][:results].map { |message| message[:id] }
  end

  test "keys that disagree with the run's own keys never call the provider" do
    run = run_for(tenant_key: "1", user_key: "user-1")

    Job.perform_now(run.id, "2", "user-1")

    assert_empty FakeGmail.current.calls
    assert_equal({ status: :unavailable, name: "gmail", label: "Gmail", reason: :scope_mismatch }, run.sections[:provider])
  end

  test "a cancelled run makes no provider call and writes nothing" do
    run = run_for
    run.cancelled = true

    Job.perform_now(run.id, "1", "user-1")

    assert_empty FakeGmail.current.calls
    assert_empty run.updates
  end

  test "a run cancelled while the provider is in flight discards its answer" do
    run = run_for
    gmail = FakeGmail.current
    FakeGmail.current = Class.new do
      define_method(:call) do |query, tenant:, user:|
        run.cancelled = true
        gmail.call(query, tenant: tenant, user: user)
      end
    end.new

    Job.perform_now(run.id, "1", "user-1")

    assert_equal 1, gmail.calls.size
    assert_empty run.updates
  end

  test "an expired run is a no-op" do
    assert_nil Job.perform_now("missing", "1", "user-1")
    assert_empty FakeGmail.current.calls
  end

  test "the search notification is allowlisted: counts, status, and keys only" do
    run = run_for

    payloads = capture_notifications("truffler.provider_search") { Job.perform_now(run.id, "1", "user-1") }

    assert_equal 1, payloads.size
    payload = payloads.first
    assert_equal %i[run_id record_type tenant_key user_key section status reason result_count error_class latency_ms].sort,
      payload.keys.sort
    assert_equal :results, payload[:status]
    assert_equal 1, payload[:result_count]
    assert_not_includes payloads.to_json, "nvoice"
  end
end
