require "test_helper"
require "minitest/mock"
require "truffler/embeddings/ruby_llm_embedder"

class EmbedderTest < Truffler::TestCase
  Fake = Truffler::Embeddings::FakeEmbedder
  Store = Truffler::Embeddings::VectorStore

  test "the fake returns deterministic unit vectors, closer for texts that share words" do
    fake = Fake.new
    invoice, receipt, trip = fake.embed([ "unpaid invoice from acme", "acme invoice receipt", "hiking trip photos" ],
      model: "m", dimensions: 64).vectors

    assert_equal invoice, fake.embed([ "unpaid invoice from acme" ], model: "m", dimensions: 64).vectors.first
    assert_equal 64, invoice.size
    assert_in_delta 1.0, Math.sqrt(invoice.sum { |value| value * value })
    assert_operator Store.cosine(invoice, receipt), :>, Store.cosine(invoice, trip)
  end

  test "emits one embed_call with tokens, cost, and latency but no text" do
    payloads = capture_notifications("truffler.embed_call") do
      Fake.new.embed([ "confidential merger memo" ], model: "text-embedding-3-small", dimensions: 8)
    end

    payload = payloads.sole
    assert_equal "text-embedding-3-small", payload[:model]
    assert_equal 1, payload[:record_count]
    assert_operator payload[:input_tokens], :>, 0
    assert payload[:tokens_estimated]
    assert_operator payload[:cost], :>, 0
    assert payload.key?(:latency_ms)
    assert_not_includes payload.to_s, "merger"
  end

  test "provider errors become ClientError without the response body" do
    fake = Fake.new.fail_with(Truffler::Test::HttpError.new(429, "rate limited on: confidential merger memo"))

    payloads = capture_notifications("truffler.embed_call") do
      error = assert_raises(Truffler::ClientError) { fake.embed([ "confidential merger memo" ], model: "m", dimensions: 8) }
      assert_equal 429, error.status
      assert_not_includes error.message, "merger"
    end

    assert_equal "Truffler::Test::HttpError", payloads.sole[:error_class]
    assert_equal 429, payloads.sole[:status]
  end

  test "a response with the wrong number of vectors fails whole" do
    embedder = Class.new(Truffler::Embeddings::Embedder) do
      def perform(texts, model:, dimensions:) = { vectors: [] }
    end

    assert_raises(Truffler::IncompleteAnswers) { embedder.new.embed([ "a" ], model: "m", dimensions: 2) }
  end

  test "the RubyLLM embedder passes model and dimensions and reads ruby_llm 1.x token counts" do
    calls = []
    legacy = Struct.new(:vectors, :model, :input_tokens)
    embed = ->(texts, **options) { calls << [ texts, options ]; legacy.new([ [ 0.1, 0.2 ] ], "text-embedding-3-small", 7) }

    result = RubyLLM.stub(:embed, embed) do
      Truffler::Embeddings::RubyLLMEmbedder.new.embed([ "hello" ], model: "text-embedding-3-small", dimensions: 2)
    end

    assert_equal [ [ [ "hello" ], { model: "text-embedding-3-small", dimensions: 2 } ] ], calls
    assert_equal [ [ 0.1, 0.2 ] ], result.vectors
    assert_equal 7, result.input_tokens
    assert_not result.tokens_estimated
  end

  test "the RubyLLM embedder reads ruby_llm 2 usage and wraps a single flat vector" do
    tokens = Struct.new(:input)
    modern = Struct.new(:vectors, :model, :tokens)
    embed = ->(*, **) { modern.new([ 0.5, 0.5 ], "text-embedding-3-small", tokens.new(3)) }

    result = RubyLLM.stub(:embed, embed) do
      Truffler::Embeddings::RubyLLMEmbedder.new.embed([ "hello" ], model: "text-embedding-3-small", dimensions: 2)
    end

    assert_equal [ [ 0.5, 0.5 ] ], result.vectors
    assert_equal 3, result.input_tokens
  end

  test "the default embedder is RubyLLM, and tests refuse live embedding" do
    assert_raises(Truffler::LiveCallInTest) { Truffler::Embeddings.embedder.embed([ "x" ], model: "m", dimensions: 2) }

    Truffler.config.embedder = nil
    assert_instance_of Truffler::Embeddings::RubyLLMEmbedder, Truffler::Embeddings.embedder
  end

  test "embedding text joins the declared fields, truncated per field" do
    Truffler.config.max_field_chars = 5
    note = EmbeddedNote.new(account_id: 1, title: "Quarterly", body: nil, color: "red")

    assert_equal "title: Quart", Truffler::Embeddings.text_for(EmbeddedNote.truffler_definition, note)
  end
end
