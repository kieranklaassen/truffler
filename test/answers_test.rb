require "test_helper"

class AnswersTest < Truffler::TestCase
  RAW = {
    "needs_action" => { "type" => "noul", "noul" => 0.82 },
    "category" => { "type" => "choice", "choice" => "billing",
                    "probabilities" => { "billing" => 0.7, "sales" => 0.3 }, "confidence" => 0.7 },
    "urgency" => { "type" => "score", "score" => 2, "legend" => { "0" => "Low", "1" => "Mid", "2" => "High" },
                   "probabilities" => { "0" => 0.0, "1" => 0.1, "2" => 0.9 }, "confidence" => 0.9 }
  }.freeze

  test "reads nouls, choices, and choice probabilities" do
    answers = Truffler::Answers.new(RAW)

    assert_in_delta 0.82, answers.noul("needs_action")
    assert_equal "billing", answers.choice(:category)
    assert_in_delta 0.3, answers.probability("category", "sales")
    assert_in_delta 0.0, answers.probability("category", "unknown")
    assert_equal({ "billing" => 0.7, "sales" => 0.3 }, answers.probabilities("category"))
  end

  test "normalizes scores to 0..1 by the legend size" do
    assert_in_delta 1.0, Truffler::Answers.new(RAW).score("urgency")

    middle = RAW.merge("urgency" => RAW["urgency"].merge("score" => 1))
    assert_in_delta 0.5, Truffler::Answers.new(middle).score("urgency")

    weighted = RAW.merge("urgency" => RAW["urgency"].merge("score" => 1.5))
    assert_in_delta 0.75, Truffler::Answers.new(weighted).score("urgency")
  end

  test "value reads any answer type as one number" do
    answers = Truffler::Answers.new(RAW)

    assert_in_delta 0.82, answers.value("needs_action")
    assert_in_delta 1.0, answers.value("urgency")
    assert_in_delta 0.7, answers.value("category")
  end

  test "raises IncompleteAnswers when a requested id is missing" do
    error = assert_raises(Truffler::IncompleteAnswers) do
      Truffler::Answers.new(RAW.except("urgency"), requested: %w[needs_action urgency])
    end
    assert_includes error.message, "urgency"
  end

  test "raises when an answer has the wrong type" do
    assert_raises(Truffler::IncompleteAnswers) { Truffler::Answers.new(RAW).noul("category") }
  end

  test "accepts symbol keys" do
    answers = Truffler::Answers.new({ spam: { type: "noul", noul: 0.1 } })

    assert_in_delta 0.1, answers.noul("spam")
  end
end
