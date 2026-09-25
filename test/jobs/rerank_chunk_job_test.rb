require "test_helper"

class RerankChunkJobTest < Truffler::TestCase
  include Truffler::Test::SmartSearchHelpers

  setup do
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new
    Truffler.config.encoding_prefetch = nil
  end

  test "scores its chunk into the buckets" do
    email = inbox_email!(subject: "invoice")
    Truffler.config.client = rerank_client({ "invoice" => 0.9 })
    run = smart(InboxEmail, "invoice")
    Truffler::Jobs::SmartSearchJob.perform_now(run.id)

    Truffler::Jobs::RerankChunkJob.perform_now(run.id, 0)

    assert_equal [ email.id ], run.promoted_ids
  end

  test "an expired run or an unknown chunk makes no Jev call" do
    Truffler.config.client = client = rerank_client

    Truffler::Jobs::RerankChunkJob.perform_now("gone", 0)
    inbox_email!(subject: "invoice")
    run = smart(InboxEmail, "invoice")
    Truffler::Jobs::SmartSearchJob.perform_now(run.id)
    Truffler::Jobs::RerankChunkJob.perform_now(run.id, 7)

    assert_empty rerank_calls(client)
  end

  test "a retried chunk that already landed is not asked again" do
    inbox_email!(subject: "invoice")
    Truffler.config.client = client = rerank_client
    run = smart(InboxEmail, "invoice")
    Truffler::Jobs::SmartSearchJob.perform_now(run.id)

    2.times { Truffler::Jobs::RerankChunkJob.perform_now(run.id, 0) }

    assert_equal 1, rerank_calls(client).size
  end
end
