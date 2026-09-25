require "test_helper"

class EvaluatorTest < Truffler::TestCase
  include Truffler::Test::ClientContract

  # Shaped like Cora's TypeSafe::Evaluation: readers only, no to_h.
  Evaluation = Struct.new(:answers, :model, :input_tokens, keyword_init: true) do
    undef_method :to_h
  end

  # Shaped like Cora's TypeSafeClient: reads `schema.questions` and returns an Evaluation.
  class SchemaHost
    attr_reader :calls

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
      @calls = []
    end

    def evaluate(state:, schema:, model: "jev-default")
      raise ArgumentError, "TypeSafe schema has no questions" if schema.empty?

      @calls << { state: state, questions: schema.questions, model: model }
      raise @error if @error

      Evaluation.new(answers: @response["answers"], model: @response["model"], input_tokens: @response.dig("usage", "input_tokens"))
    end
  end

  def client_answering(response)
    @host = SchemaHost.new(response: response)
    Truffler::Clients::Evaluator.new(@host)
  end

  def client_raising(error)
    Truffler::Clients::Evaluator.new(SchemaHost.new(error: error))
  end

  test "hands the host a schema object whose questions are the wire-shape question hash, and passes the model" do
    answers = client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

    assert_equal [ { state: STATE, questions: QUESTIONS, model: "jev-1.13" } ], @host.calls
    assert_equal 120, answers.usage.input_tokens
    assert_not answers.usage.estimated
  end

  test "the schema object also reads like the question hash" do
    schema = Truffler::Clients::Evaluator::Schema.new(questions: QUESTIONS)

    assert_equal QUESTIONS, schema.to_h
    assert_equal QUESTIONS.keys, schema.ids
    assert_equal 2, schema.size
    assert_equal QUESTIONS["r001__spam"], schema["r001__spam"]
    assert_equal QUESTIONS.as_json, schema.as_json
  end

  test "reads usage from a usage hash, and estimates tokens when the evaluation has none" do
    with_usage = Struct.new(:answers, :model, :usage).new(RESPONSE["answers"], "jev-1.13", { input_tokens: 77 })
    bare = Struct.new(:answers).new(RESPONSE["answers"])

    counted = Truffler::Clients::Evaluator.new(Truffler::Test::HostClient.new(response: with_usage)).ask(state: STATE, questions: QUESTIONS)
    estimated = Truffler::Clients::Evaluator.new(Truffler::Test::HostClient.new(response: bare)).ask(state: STATE, questions: QUESTIONS)

    assert_equal 77, counted.usage.input_tokens
    assert estimated.usage.estimated
    assert_equal "angry", estimated.choice("r001__tone")
  end

  test "a host returning a plain response hash still works" do
    answers = Truffler::Clients::Evaluator.new(Truffler::Test::HostClient.new(response: RESPONSE)).ask(state: STATE, questions: QUESTIONS)

    assert_in_delta 0.25, answers.noul("r001__spam")
  end
end
