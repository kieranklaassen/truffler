require "test_helper"

class FakeTest < Truffler::TestCase
  include Truffler::Test::ClientContract

  def client_answering(response)
    fake = Truffler::Clients::Fake.new(model: response["model"])
    response["answers"].each do |id, answer|
      fake.answer(id, answer["type"] == "noul" ? answer["noul"] : answer["probabilities"])
    end
    fake.answer_without(*(QUESTIONS.keys - response["answers"].keys))
    fake
  end

  def client_raising(error)
    Truffler::Clients::Fake.new.tap { |fake| fake.fail_with(error) }
  end

  test "defaults to a no, the first option, and the lowest level" do
    questions = Truffler::Questions.build do |q|
      q.noul :a, instructions: "?"
      q.choice :b, instructions: "?", criteria: { x: nil, y: nil }
      q.score :c, instructions: "?", criteria: %w[low high]
    end

    answers = Truffler::Clients::Fake.new.ask(state: {}, questions: questions)

    assert_in_delta 0.0, answers.noul("a")
    assert_equal "x", answers.choice("b")
    assert_in_delta 0.0, answers.score("c")
  end

  test "scripts answers by label suffix and by block, and records calls" do
    fake = Truffler::Clients::Fake.new
    fake.answer(:spam) { |tag, state| state.dig("records", tag, "body").include?("watches") ? 0.9 : 0.1 }
    fake.answer(:urgency, 2)
    questions = Truffler::Questions.build do |q|
      q.noul :r001__spam, instructions: "?"
      q.noul :r002__spam, instructions: "?"
      q.score :r001__urgency, instructions: "?", criteria: %w[low mid high]
    end
    state = { "records" => { "r001" => { "body" => "cheap watches" }, "r002" => { "body" => "lunch?" } } }

    answers = fake.ask(state: state, questions: questions)

    assert_in_delta 0.9, answers.noul("r001__spam")
    assert_in_delta 0.1, answers.noul("r002__spam")
    assert_in_delta 1.0, answers.score("r001__urgency")
    assert_equal 1, fake.calls.size
    assert_equal questions, fake.calls.first[:questions]
  end

  test "recovers after a scripted failure is cleared" do
    fake = Truffler::Clients::Fake.new
    fake.fail_with(Truffler::Test::HttpError.new(503, "down"))
    assert_raises(Truffler::ClientError) { fake.ask(state: {}, questions: QUESTIONS) }

    fake.fail_with(nil)
    assert_in_delta 0.0, fake.ask(state: {}, questions: QUESTIONS).noul("r001__spam")
  end
end
