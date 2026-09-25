require "test_helper"

class CallableTest < Truffler::TestCase
  include Truffler::Test::ClientContract

  def client_answering(response)
    @host = Truffler::Test::HostClient.new(response: response)
    Truffler::Clients::Callable.new(@host)
  end

  def client_raising(error)
    Truffler::Clients::Callable.new(Truffler::Test::HostClient.new(error: error))
  end

  test "forwards state and the question hash as schema" do
    client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS)

    assert_equal [ { state: STATE, schema: QUESTIONS } ], @host.calls
  end

  test "accepts a host that returns only the answers hash and estimates tokens" do
    host = Truffler::Test::HostClient.new(response: RESPONSE["answers"])

    answers = Truffler::Clients::Callable.new(host).ask(state: STATE, questions: QUESTIONS, model: "jev-latest")

    assert_in_delta 0.25, answers.noul("r001__spam")
    assert_equal "jev-latest", answers.model
    assert answers.usage.estimated
    assert_operator answers.usage.input_tokens, :>, 0
  end

  test "passes the model when the host accepts it" do
    host = Class.new do
      attr_reader :model

      def evaluate(state:, schema:, model:)
        @model = model
        Truffler::Test::ClientContract::RESPONSE
      end
    end.new

    Truffler::Clients::Callable.new(host).ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

    assert_equal "jev-1.13", host.model
  end
end
