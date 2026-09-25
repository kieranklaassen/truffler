require "test_helper"
require "truffler/lenses/ruby_llm_generator"

class DrafterTest < Truffler::TestCase
  include Truffler::Test::LensHelpers

  Drafter = Truffler::Lenses::Drafter
  Scope = Truffler::Lenses::Scope

  test "drafting happy people who speak Dutch reuses sentiment and adds one language choice with an other option" do
    draft = dutch_draft

    assert_equal [ "sentiment" ], draft.reused
    assert_equal [ "language" ], draft.questions.keys
    assert_equal "choice", draft.questions["language"]["type"]
    assert_includes draft.questions["language"]["criteria"].keys, "other"
    assert_equal "Happy Dutch speakers", draft.name
    assert_equal Scope.tenant("1"), draft.scope
  end

  test "the drafting request carries the description and vocabulary but never record text" do
    feed_message("Hallo allemaal, wat een prachtige dag vandaag", author: "Joost van der Berg")

    dutch_draft
    prompt = @generator.calls.sole[:prompt]
    request = JSON.parse(prompt)

    assert_equal "happy people who speak Dutch", request["description"]
    assert_equal %w[relevant sentiment], request["existing_labels"].map { |label| label["key"] }.sort
    assert_not_includes prompt, "prachtige"
    assert_not_includes prompt, "Joost"
    assert_equal Drafter::SCHEMA, @generator.calls.sole[:schema]
  end

  test "visible lens labels are offered for reuse, and reusing an unknown label is rejected" do
    lens = dutch_lens
    @generator.draft(/formal/, reuse: [ "lens:#{lens.id}:language" ],
      questions: [ { key: "formal", type: "noul", instructions: "Is the message formal?" } ])

    draft = Drafter.draft("formal Dutch", model: FeedMessage, scope: Scope.tenant("1"))
    assert_equal [ "lens:#{lens.id}:language" ], draft.reused

    @generator.draft(/ghost/, reuse: [ "haunted" ], questions: [])
    error = assert_raises(Truffler::InvalidLens) { Drafter.draft("ghost", model: FeedMessage, scope: Scope.tenant("1")) }
    assert_match(/haunted/, error.message)
  end

  test "a draft with 11 score levels or 300 choice options is rejected before any Jev call" do
    @generator.draft(/levels/, questions: [ { key: "warmth", type: "score", instructions: "How warm?", levels: (1..11).to_a } ])
    @generator.draft(/options/, questions: [ { key: "city", type: "choice", instructions: "Which city?",
                                               options: (1..300).map { |i| "city_#{i}" } } ])

    levels = assert_raises(Truffler::InvalidLens) { Drafter.draft("levels", model: FeedMessage, scope: Scope.tenant("1")) }
    options = assert_raises(Truffler::InvalidLens) { Drafter.draft("options", model: FeedMessage, scope: Scope.tenant("1")) }

    assert_match(/11 score levels exceed Jev's limit of 10/, levels.message)
    assert_match(/300 choice options exceed Jev's limit of 255/, options.message)
    assert_empty @jev.calls
  end

  test "the limits themselves are allowed" do
    @generator.draft(/edge/, questions: [
      { key: "warmth", type: "score", instructions: "How warm?", levels: (1..10).to_a },
      { key: "city", type: "choice", instructions: "Which city?", options: (1..255).map { |i| "city_#{i}" } }
    ])

    draft = Drafter.draft("edge", model: FeedMessage, scope: Scope.tenant("1"))

    assert_equal 10, draft.questions["warmth"]["criteria"].size
    assert_equal 255, draft.questions["city"]["criteria"].size
  end

  test "malformed drafts are rejected: shadowing a declared label, bad keys, unknown types, empty lenses" do
    {
      "shadow" => [ { key: "sentiment", type: "noul", instructions: "Happy?" } ],
      "badkey" => [ { key: "Bad Key", type: "noul", instructions: "Happy?" } ],
      "badtype" => [ { key: "mood", type: "vibes", instructions: "Happy?" } ],
      "noinstructions" => [ { key: "mood", type: "noul", instructions: "" } ],
      "empty" => []
    }.each do |description, questions|
      @generator.draft(/\A#{description}\z/, questions: questions)
      assert_raises(Truffler::InvalidLens, description) { Drafter.draft(description, model: FeedMessage, scope: Scope.tenant("1")) }
    end
  end

  test "tenant and user lenses on a scoped model need a tenant, and a description is required" do
    assert_raises(ArgumentError) { Drafter.draft("dutch", model: FeedMessage, scope: Scope.user(nil, "u1")) }
    assert_raises(Truffler::InvalidLens) { Drafter.draft(" ", model: FeedMessage, scope: Scope.app) }
  end

  test "drafting emits lens_draft instrumentation without the description" do
    payloads = capture_notifications("truffler.lens_draft") { dutch_draft }

    assert_equal "drafted", payloads.sole[:outcome]
    assert_equal 1, payloads.sole[:question_count]
    assert_equal "FeedMessage", payloads.sole[:record_type]
    assert_not_includes payloads.sole.to_s, "Dutch"
  end

  test "the RubyLLM generator reads ruby_llm 2 parsed output" do
    body = { "name" => "Dutch", "reuse" => [], "questions" => [] }
    message = RubyLLM::Message.new(role: :assistant, content: JSON.generate(body), model: "gpt-4.1-mini", input_tokens: 42)
    chat = FakeChat.new(message)

    result = generator_with(chat).generate(prompt: "{}", schema: Drafter::SCHEMA, model: "gpt-4.1-mini")

    assert_equal body, result[:draft]
    assert_equal 42, result[:input_tokens]
    assert_equal "gpt-4.1-mini", result[:model]
    assert_equal Drafter::SCHEMA, chat.schema
    assert_equal({ model: "gpt-4.1-mini" }, @chat_args)
  end

  test "the RubyLLM generator reads ruby_llm 1.x hash content and uses the default model when none is pinned" do
    body = { "name" => "Dutch", "reuse" => [], "questions" => [] }
    message = Struct.new(:content, :model_id, :input_tokens).new(body, "gpt-4o", 7)

    result = generator_with(FakeChat.new(message)).generate(prompt: "{}", schema: Drafter::SCHEMA)

    assert_equal body, result[:draft]
    assert_equal "gpt-4o", result[:model]
    assert_equal({}, @chat_args)
  end

  test "the RubyLLM generator rejects unstructured output" do
    message = Struct.new(:content).new("not json")

    assert_raises(Truffler::InvalidLens) { generator_with(FakeChat.new(message)).generate(prompt: "{}", schema: {}) }
  end

  class FakeChat
    attr_reader :schema, :asked

    def initialize(message)
      @message = message
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt)
      @asked = prompt
      @message
    end
  end

  private

  def generator_with(chat)
    test = self
    generator = Truffler::Lenses::RubyLLMGenerator.new
    generator.define_singleton_method(:chat) do |**args|
      test.instance_variable_set(:@chat_args, args)
      chat
    end
    generator
  end
end
