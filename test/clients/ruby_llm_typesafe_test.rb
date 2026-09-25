require "test_helper"
require "truffler/clients/ruby_llm_typesafe"

class RubyLLMTypeSafeTest < Truffler::TestCase
  include Truffler::Test::ClientContract

  class FakeChat
    attr_reader :schema, :asked

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(text)
      @asked = text
      raise @error if @error

      RubyLLM::Message.new(role: :assistant, content: JSON.generate(@response["answers"]),
        model: @response["model"], input_tokens: @response.dig("usage", "input_tokens"))
    end
  end

  def client_answering(response)
    @chat = FakeChat.new(response: response)
    stub_chat(@chat)
  end

  def client_raising(error)
    stub_chat(FakeChat.new(error: error))
  end

  test "sends the pinned model, the question payload, and the state as JSON" do
    Truffler.config.model = "jev-1.13"
    client = client_answering(RESPONSE)

    answers = client.ask(state: STATE, questions: QUESTIONS)

    assert_equal({ model: "jev-1.13", provider: :typesafe }, @chat_args)
    assert_equal QUESTIONS, @chat.schema.questions
    assert_equal STATE, JSON.parse(@chat.asked)
    assert_equal 120, answers.usage.input_tokens
    assert_not answers.usage.estimated
  end

  private

  def stub_chat(chat)
    test = self
    client = Truffler::Clients::RubyLLMTypeSafe.new
    client.define_singleton_method(:chat) do |**args|
      test.instance_variable_set(:@chat_args, args)
      chat
    end
    client
  end
end
