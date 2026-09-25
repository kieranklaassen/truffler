require "test_helper"

class BroadcasterTest < Truffler::TestCase
  Broadcaster = Truffler::Broadcaster

  test "the ping is data free: exactly run_id, section, and changed_at on the user's stream" do
    cable = Truffler::Test::FakeCable.new
    Truffler.config.broadcaster = cable

    assert Broadcaster.ping("user-1", run_id: "run-1", section: :smart)

    stream, payload = cable.pings.sole
    assert_equal "truffler:user-1", stream
    assert_equal %i[changed_at run_id section], payload.keys.sort
    assert_equal "run-1", payload[:run_id]
    assert_equal "smart", payload[:section]
    assert_kind_of Time, Time.iso8601(payload[:changed_at])
  end

  test "a broadcast error is reported with its class and swallowed" do
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new(error: RuntimeError.new("socket gone with record text"))

    payloads = capture_notifications("truffler.broadcast_failed") do
      assert_not Broadcaster.ping("user-1", run_id: "run-1", section: "provider")
    end

    assert_equal [ { run_id: "run-1", section: "provider", error_class: "RuntimeError" } ], payloads
  end

  test "no user key or no Action Cable means no ping" do
    cable = Truffler::Test::FakeCable.new
    Truffler.config.broadcaster = cable

    assert_not Broadcaster.ping(nil, run_id: "run-1", section: "smart")
    assert_empty cable.pings

    Truffler.config.broadcaster = nil
    assert_nil Broadcaster.server unless defined?(ActionCable)
    assert_not Broadcaster.ping("user-1", run_id: "run-1", section: "smart") unless defined?(ActionCable)
  end

  test "a broadcast failure does not fail the chunk job" do
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new(error: RuntimeError.new("down"))
    Truffler.config.encoding_prefetch = nil
    email = InboxEmail.create!(account_id: 1, subject: "invoice")
    Truffler.config.client = Truffler::Clients::Fake.new.answer(:relevance, 0.9)
    run = InboxEmail.jev_smart_search("invoice", tenant: 1, scope: InboxEmail.all, user: "user-1")

    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)
    perform_enqueued_jobs(only: Truffler::Jobs::RerankChunkJob)

    assert_equal [ email.id ], run.promoted_ids
  end
end
