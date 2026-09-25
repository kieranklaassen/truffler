require "test_helper"

class PrivacyTest < Truffler::TestCase
  SECRET = "the vault code is swordfish-7731"

  setup do
    @log = StringIO.new
    logger = ActiveSupport::Logger.new(@log)
    Truffler.config.logger = logger
    @previous_loggers = [ ActiveRecord::Base.logger, ActiveJob::Base.logger ]
    ActiveRecord::Base.logger = logger
    ActiveJob::Base.logger = logger
    fake = Truffler::Clients::Fake.new
    fake.answer(:spam) { |tag, state| state.dig("records", tag, "body").include?("swordfish") ? 0.1 : 0.9 }
    Truffler.config.client = fake
  end

  teardown do
    ActiveRecord::Base.logger, ActiveJob::Base.logger = @previous_loggers
  end

  test "labeling an encrypted record leaves no body text in jobs, tables, logs, or notifications" do
    payloads = capture_notifications(/\Atruffler\./) do
      SecretNote.create!(account_id: 3, title: "Note", body: SECRET)
      assert_no_secret enqueued_jobs.map { |job| job[:args] }.to_s, "job arguments"
      perform_enqueued_jobs
    end

    assert_in_delta 0.1, Truffler::Records::Label.sole.value
    assert_not_equal SECRET, SecretNote.connection.select_value("SELECT body FROM secret_notes")
    truffler_tables.each do |table|
      rows = ActiveRecord::Base.connection.select_all("SELECT * FROM #{table}").rows
      assert_no_secret rows.to_s, table
    end
    assert_no_secret @log.string, "logs"
    assert_not_empty payloads
    assert_no_secret payloads.to_s, "notifications"
  end

  test "a failed labeling call stores only the error class" do
    Truffler.config.client.fail_with(Truffler::Test::HttpError.new(500, "echo: #{SECRET}"))
    SecretNote.create!(account_id: 3, title: "Note", body: SECRET)
    clear_enqueued_jobs

    Truffler::Jobs::LabelFlushJob.perform_now("SecretNote", "3")

    truffler_tables.each do |table|
      assert_no_secret ActiveRecord::Base.connection.select_all("SELECT * FROM #{table}").rows.to_s, table
    end
    assert_no_secret @log.string, "logs"
  end

  private

  def truffler_tables
    ActiveRecord::Base.connection.tables.grep(/\Atruffler_/)
  end

  def assert_no_secret(text, where)
    assert_not_includes text, "swordfish", "secret text leaked into #{where}"
  end
end
