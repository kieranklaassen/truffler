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

    section = Truffler::SmartSearch.find(run.id, user: "user-1", tenant: 1).provider_section
    assert_equal :results, section[:status].to_sym
    assert_equal "Gmail", section[:label]
    assert_equal [ "g-1" ], section[:results].map { |result| result[:id] || result["id"] }
  end

  test "an intent Smart search whose keystroke list is strong does not run the provider" do
    4.times { |index| provider_email!(subject: "Invoice follow up #{index}") }

    run = LocalProviderEmail.jev_smart_search("follow up", tenant: 1, scope: LocalProviderEmail.all, user: "user-1")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)

    assert_not run.local_weak?
    assert_no_enqueued_jobs only: Truffler::Jobs::ProviderSearchJob
  end

  test "an intent Smart search whose keystroke list is weak runs the provider" do
    provider_email!(subject: "Invoice follow up")

    run = LocalProviderEmail.jev_smart_search("follow up", tenant: 1, scope: LocalProviderEmail.all, user: "user-1")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)

    assert run.local_weak?
    assert_enqueued_jobs 1, only: Truffler::Jobs::ProviderSearchJob
  end

  test "an exact-text Smart search runs the provider even when the keystroke list is strong" do
    4.times { |index| provider_email!(subject: "INV-4471 reminder #{index}") }

    LocalProviderEmail.jev_smart_search("INV-4471", tenant: 1, scope: LocalProviderEmail.all, user: "user-1")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)

    assert_enqueued_jobs 1, only: Truffler::Jobs::ProviderSearchJob
  end

  private

  def provider_email!(subject:)
    LocalProviderEmail.create!(account_id: 1, subject: subject, body: "", received_at: Time.current)
  end
end
