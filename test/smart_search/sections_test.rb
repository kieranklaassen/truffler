require "test_helper"

class SmartSearchSectionsTest < Truffler::TestCase
  include Truffler::Test::SmartSearchHelpers

  class FakeProviders
    attr_reader :calls

    def initialize(&block)
      @calls = []
      @block = block
    end

    def start(run, query:, tenant_key:, user_key:)
      @calls << { run_id: run.id, query: query, tenant_key: tenant_key, user_key: user_key }
      @block&.call(run)
    end
  end

  setup do
    @cable = Truffler::Test::FakeCable.new
    Truffler.config.broadcaster = @cable
    Truffler.config.encoding_prefetch = nil
    Truffler.config.client = rerank_client
    inbox_email!(subject: "invoice 4471")
  end

  test "the provider section is absent until something writes it" do
    run = smart(InboxEmail, "invoice 4471")

    assert_equal :absent, run.provider_section[:status]
    Truffler::SmartSearch::Dispatcher.new(providers: Object.new).call(run)
    assert_equal :absent, run.provider_section[:status]
  end

  test "the explicit action hands the run to the provider backup with the query, tenant, and user" do
    providers = FakeProviders.new { |run| run.update_section(:provider, status: :pending) }
    run = smart(InboxEmail, "invoice 4471")

    Truffler::SmartSearch::Dispatcher.new(providers: providers).call(run)

    assert_equal [ { run_id: run.id, query: "invoice 4471", tenant_key: "1", user_key: "user-1" } ], providers.calls
    assert_equal :pending, run.provider_section[:status]
    assert_equal %w[provider], @cable.sections
  end

  test "the provider backup still starts when rerank is paused (AE5 leaves R19 alone)" do
    providers = FakeProviders.new
    run = smart(InboxEmail, "invoice 4471")

    Truffler::SmartSearch::Dispatcher.new(providers: providers, budget: Truffler::Test::DeniedBudget.new).call(run)

    assert_equal 1, providers.calls.size
    assert_equal :paused, run.status
  end

  test "a provider start that raises marks the section unavailable and the rerank continues" do
    providers = FakeProviders.new { raise ArgumentError, "secret detail" }
    run = smart(InboxEmail, "invoice 4471")

    Truffler::SmartSearch::Dispatcher.new(providers: providers).call(run)

    assert_equal({ "status" => :unavailable, "error_class" => "ArgumentError" }, run.provider_section.to_h)
    assert_equal 1, run.chunk_count
  end

  test "update_section writes each state through the run store and pings that section" do
    run = smart(InboxEmail, "invoice 4471")

    %i[pending results empty unavailable].each do |state|
      assert run.update_section(:provider, status: state, results: state == :results ? [ 1, 2 ] : [])
      assert_equal state, Truffler::SmartSearch.find(run.id, user: "user-1", tenant: 1).provider_section[:status]
    end

    assert_equal [ 1, 2 ], Truffler::SmartSearch.find(run.id, user: "user-1", tenant: 1).tap { |found| found.update_section(:provider, status: :results, results: [ 1, 2 ]) }
      .provider_section[:results]
    assert_equal %w[provider] * 5, @cable.sections
    assert_equal({ status: :results, results: [ 1, 2 ] }, run.to_h[:sections][:provider])
  end

  test "provider_section= writes without a ping" do
    run = smart(InboxEmail, "invoice 4471")

    run.provider_section = { status: :pending }

    assert_equal :pending, Truffler::SmartSearch.find(run.id, user: "user-1", tenant: 1).provider_section[:status]
    assert_empty @cable.pings
  end

  test "a cancelled or expired run ignores section updates, and the smart section is not writable" do
    run = smart(InboxEmail, "invoice 4471")
    assert_raises(ArgumentError) { run.update_section(:smart, status: :pending) }

    run.cancel!
    assert_not run.update_section(:provider, status: :pending)
    assert_not Truffler::SmartSearch.find("missing", user: "user-1", tenant: 1).update_section(:provider, status: :pending)
    assert_equal :absent, run.provider_section[:status]
  end
end
