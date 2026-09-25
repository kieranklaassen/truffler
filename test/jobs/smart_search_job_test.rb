require "test_helper"

class SmartSearchJobTest < Truffler::TestCase
  include Truffler::Test::SmartSearchHelpers

  setup do
    Truffler.config.broadcaster = Truffler::Test::FakeCable.new
    Truffler.config.encoding_prefetch = nil
  end

  test "plans the run and enqueues one chunk job per chunk, each carrying only the run id and index" do
    Truffler.config.rerank_chunk_size = 2
    3.times { |index| inbox_email!(subject: "invoice #{index}") }
    run = smart(InboxEmail, "invoice")
    clear_enqueued_jobs

    Truffler::Jobs::SmartSearchJob.perform_now(run.id)

    assert_equal [ [ run.id, 0 ], [ run.id, 1 ] ], smart_job_args
    assert_equal :running, run.status
  end

  test "an empty candidate set completes at once and pings" do
    cable = Truffler.config.broadcaster
    run = smart(InboxEmail, "nothing matches")

    Truffler::Jobs::SmartSearchJob.perform_now(run.id)

    assert_equal :complete, run.status
    assert run.no_strong_matches?
    assert_equal [ "smart" ], cable.sections
  end

  test "running twice plans once" do
    inbox_email!(subject: "invoice")
    run = smart(InboxEmail, "invoice")
    clear_enqueued_jobs

    2.times { Truffler::Jobs::SmartSearchJob.perform_now(run.id) }

    assert_equal 1, smart_job_args.size
  end
end
