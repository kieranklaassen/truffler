require "test_helper"
require "tmpdir"

class CassetteTest < Truffler::TestCase
  include Truffler::Test::ClientContract

  setup { @dir = Dir.mktmpdir("truffler-cassettes") }
  teardown { FileUtils.remove_entry(@dir) }

  def client_answering(response)
    inner = Truffler::Clients::Callable.new(Truffler::Test::HostClient.new(response: response))
    Truffler::Clients::Cassette.new(inner, dir: @dir, mode: :record)
  end

  def client_raising(error)
    inner = Truffler::Clients::Callable.new(Truffler::Test::HostClient.new(error: error))
    Truffler::Clients::Cassette.new(inner, dir: @dir, mode: :record)
  end

  test "replays a recording without calling the inner client" do
    host = Truffler::Test::HostClient.new(response: RESPONSE)
    recorder = Truffler::Clients::Cassette.new(Truffler::Clients::Callable.new(host), dir: @dir, mode: :record)
    recorded = recorder.ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

    replayer = Truffler::Clients::Cassette.new(Truffler::Clients::Callable.new(host), dir: @dir, mode: :replay)
    replayed = replayer.ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

    assert_equal 1, host.calls.size
    assert_equal recorded.raw, replayed.raw
    assert_equal 120, replayed.usage.input_tokens
  end

  test "reordered request keys hit the same recording" do
    client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")
    reordered_state = { "records" => STATE["records"], "task" => STATE["task"] }
    reordered_questions = QUESTIONS.to_a.reverse.to_h

    replay = Truffler::Clients::Cassette.new(nil, dir: @dir, mode: :replay)

    assert_in_delta 0.25, replay.ask(state: reordered_state, questions: reordered_questions, model: "jev-1.13").noul("r001__spam")
  end

  test "stores only answers, model, and usage" do
    client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

    recording = JSON.parse(File.read(Dir[File.join(@dir, "*.json")].sole))

    assert_equal %w[answers model request_hash usage], recording.keys.sort
    assert_not_includes recording.to_s, "watches"
  end

  test "a replay miss raises CassetteMiss naming the hash, not the request" do
    replay = Truffler::Clients::Cassette.new(nil, dir: @dir, mode: :replay)

    error = assert_raises(Truffler::CassetteMiss) { replay.ask(state: STATE, questions: QUESTIONS) }

    assert_match(/[0-9a-f]{64}/, error.message)
    assert_not_includes error.message, "watches"
  end

  test "auto mode records on a miss and replays on a hit" do
    host = Truffler::Test::HostClient.new(response: RESPONSE)
    auto = Truffler::Clients::Cassette.new(Truffler::Clients::Callable.new(host), dir: @dir, mode: :auto)

    2.times { auto.ask(state: STATE, questions: QUESTIONS) }

    assert_equal 1, host.calls.size
  end
end
