require "test_helper"

class QuestionsTest < Truffler::TestCase
  test "builds noul, choice, and score questions in the TypeSafe wire shape" do
    questions = Truffler::Questions.build do |q|
      q.noul :needs_action, instructions: "Does this need action?", criteria: { true => "Asks for a reply", false => "FYI" }
      q.choice :category, instructions: "Which category?", criteria: { billing: "Payments", sales: nil, other: "Anything else" }
      q.score :urgency, instructions: "How urgent?", criteria: { 0 => "Whenever", 1 => "This week", 2 => "Today" }
    end

    assert_equal %w[needs_action category urgency], questions.keys
    assert_equal({ "type" => "noul", "instructions" => "Does this need action?",
                   "criteria" => { "true" => "Asks for a reply", "false" => "FYI" } }, questions["needs_action"])
    assert_equal "choice", questions["category"]["type"]
    assert_equal({ "billing" => "Payments", "sales" => nil, "other" => "Anything else" }, questions["category"]["criteria"])
    assert_equal({ "type" => "score", "instructions" => "How urgent?", "criteria" => [ "Whenever", "This week", "Today" ] },
      questions["urgency"])
  end

  test "keeps structured instructions as JSON data" do
    questions = Truffler::Questions.build { |q| q.noul :spam, instructions: { question: "Spam?", record: "r001" } }

    assert_equal({ "question" => "Spam?", "record" => "r001" }, questions["spam"]["instructions"])
    assert_not questions["spam"].key?("criteria")
  end

  test "rejects ids outside lowercase letters, digits, and underscores" do
    [ "Needs-Action", "a b", "", "é" ].each do |id|
      assert_raises(ArgumentError, id) { Truffler::Questions.build { |q| q.noul id, instructions: "x" } }
    end
  end

  test "rejects duplicate ids, empty choices, and one-level scores" do
    assert_raises(ArgumentError) do
      Truffler::Questions.build do |q|
        q.noul :a, instructions: "x"
        q.noul :a, instructions: "y"
      end
    end
    assert_raises(ArgumentError) { Truffler::Questions.build { |q| q.choice :c, instructions: "x", criteria: {} } }
    assert_raises(ArgumentError) { Truffler::Questions.build { |q| q.score :s, instructions: "x", criteria: [ "only" ] } }
  end

  test "tags number records and prefix question ids" do
    assert_equal "r001", Truffler::Questions.tag("r", 1)
    assert_equal "c012", Truffler::Questions.tag("c", 12)
    assert_equal "r001__needs_action", Truffler::Questions.tagged_id("r001", :needs_action)
    assert_equal [ "r001", "needs_action" ], Truffler::Questions.split_id("r001__needs_action")
  end
end
