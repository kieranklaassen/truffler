require "test_helper"

class SmartProviderIntegrationTest < Truffler::TestCase
  FakeGmail = Truffler::Test::FakeGmail

  setup do
    Truffler.config.client = Truffler::Clients::Fake.new
    Truffler.config.encoding_deadline = 0
    FakeGmail.current = FakeGmail.new("1" => [ { id: "g-1", subject: "Invoice 4471" } ])
  end

  teardown { FakeGmail.current = nil }

  test "an exact-text Smart search on a model with no local text fills the provider section through the real run" do
    run = GmailEmail.jev_smart_search("invoice 4471", tenant: 1, scope: GmailEmail.all, user: "user-1")

    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)
    perform_enqueued_jobs(only: Truffler::Jobs::ProviderSearchJob)

    section = Truffler::SmartSearch::Run.find(run.id).provider_section
    assert_equal :results, section[:status].to_sym
    assert_equal "Gmail", section[:label]
    assert_equal [ "g-1" ], section[:results].map { |result| result[:id] || result["id"] }
  end
end
