require "test_helper"

class OptionSearchTextTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Encoder = Truffler::QueryEncoding::Encoder
  Query = Truffler::Search::Query
  LabelDefinition = Truffler::LabelDefinition
  Backfill = Truffler::Labeling::Backfill
  Label = Truffler::Records::Label

  CORA = "Cora, the AI email assistant that drafts replies and summarizes long threads for busy support teams".freeze

  setup do
    @fake = Truffler::Clients::Fake.new { |tag| { "intent" => "ignore", "option" => Truffler::NO_OPTION, "token" => "keyword" }[tag] }
    Truffler.config.client = @fake
  end

  def product(search: "Cora email assistant", description: CORA, **options)
    LabelDefinition.new(:product, :choice, question: "Which product is this about?", filter_at: 0.5,
      options: { "prod-a1" => { description: description, search: search }, "prod-b2" => "Billing portal" }, **options)
  end

  def define_model(name, table: "emails", &block)
    Class.new(ActiveRecord::Base) do
      self.table_name = table
      define_singleton_method(:name) { name }
      include Truffler::Model
      class_eval(&block)
    end
  end

  def product_model(label = product)
    define_model("SearchTextEmail") do
      truffler do
        tenant :account_id
        reads :subject
        keyword :subject
      end
    end.tap { |model| replace_label(model, label) }
  end

  def replace_label(model, label)
    definition = model.truffler_definition
    replaced = definition.dup
    replaced.instance_variable_set(:@labels, definition.labels.merge(label.key => label))
    model.truffler_definition = replaced
  end

  def encode(model, text)
    encoder = Encoder.new
    request = encoder.request(model, Query.new(text), tenant_key: "1")
    answers = @fake.ask(state: request.state, questions: request.questions, priority: :encode)
    encoder.encoding_for(model, request, answers, tenant_key: "1")
  end

  def label_all(model)
    states = Truffler::Labeling::Queue.new(model).claim("1", priority: :live, limit: 10)
    Truffler::Labeling::Labeler.new(model).label(states, priority: :live)
  end

  def encoding_key(model)
    Truffler::Search::EncodingCache.new.key(model, Query.new("cora"), tenant_key: "1", user_key: "user-1")
  end

  test "0.1.4: an option's search text, not its long description, drives query-word matching and option_names" do
    model = product_model
    @fake.answer("intent__product", "filter").answer("option__product", "prod-a1")

    encoding = encode(model, "cora assistant drafts replies")
    request = Encoder.new.request(model, Query.new("cora"), tenant_key: "1")

    assert_equal({ "product:prod-a1" => 0.5 }, encoding.filters)
    assert_equal %w[cora assistant], encoding.label_term_tokens
    assert_equal %w[drafts replies], encoding.keyword_tokens
    assert_equal({ "prod-a1" => "Cora email assistant", "prod-b2" => "Billing portal" }, request.state["labels"]["product"]["option_names"])
    assert_equal({ "prod-a1" => CORA, "prod-b2" => "Billing portal", Truffler::NO_OPTION => "The query names none of these" },
      request.questions["option__product"]["criteria"])
    assert_equal({ "prod-a1" => CORA, "prod-b2" => "Billing portal" }, model.truffler_definition.label(:product).question("1")["criteria"])
  end

  test "0.1.4: a per-tenant callable may return the same hash shape, and plain descriptions still work" do
    label = LabelDefinition.new(:tool, :choice, question: "Which tool?",
      options: ->(_tenant) { { "p_17" => { "description" => "A long writing tool blurb", "search" => "Spiral" }, "p_18" => "Quill" } })

    assert_equal({ "p_17" => "A long writing tool blurb", "p_18" => "Quill" }, label.options("1"))
    assert_equal({ "p_17" => "Spiral", "p_18" => "Quill" }, label.option_names("1"))
    assert_equal({ "cora" => "Cora" }, LabelDefinition.new(:p, :choice, question: "Which?", options: { "cora" => "Cora" }).option_names)
  end

  test "0.1.4: editing only the search text keeps label fingerprints and record states current but changes the encoding cache key" do
    model = product_model
    @fake.answer(:product, "prod-a1")
    Array.new(2) { |index| model.create!(account_id: 1, subject: "Cora #{index}") }
    label_all(model)
    fingerprints = model.truffler_definition.vocabulary.fingerprints(tenant_key: "1", all_users: true)
    version = model.truffler_definition.vocabulary.version(tenant_key: "1", all_users: true)
    key = encoding_key(model)
    calls = @fake.calls.size

    replace_label(model, product(search: "Cora inbox helper"))

    assert_equal fingerprints, model.truffler_definition.vocabulary.fingerprints(tenant_key: "1", all_users: true)
    assert_equal version, model.truffler_definition.vocabulary.version(tenant_key: "1", all_users: true)
    assert_equal 0, Backfill.status(model)[:stale]
    assert_equal 2, Backfill.status(model)[:current]
    assert_equal [ :complete, 0, 0 ], Backfill.new(model).run.then { |result| [ result.status, result.labeled, result.requests ] }
    assert_equal calls, @fake.calls.size
    assert_not_equal key, encoding_key(model)

    replace_label(model, product(search: "Cora inbox helper", description: "#{CORA}, now with calendars"))
    assert_not_equal fingerprints, model.truffler_definition.vocabulary.fingerprints(tenant_key: "1", all_users: true)
  end

  test "0.1.4: editing a supplied label's descriptions or search texts does not stale its rows but changes the encoding cache key" do
    sentiment = lambda do |description, negative|
      LabelDefinition.new(:sentiment, :choice, from: ->(record) { record.sentiment }, description: description, filter_at: 0.5,
        options: { "positive" => "Happy", "negative" => { description: negative, search: "angry upset" } })
    end
    model = define_model("SearchTextFeedback", table: "feedbacks") do
      truffler do
        tenant :account_id
        reads :body
        label :sentiment, :choice, options: %w[positive negative], from: ->(record) { record.sentiment }
      end
    end
    replace_label(model, sentiment.call("overall sentiment", "Unhappy"))
    records = Array.new(2) { model.create!(account_id: 1, body: "Export broke", sentiment: "negative") }
    label_all(model)
    fingerprint = model.truffler_definition.label(:sentiment).supplied_fingerprint("1")
    key = Truffler::Search::EncodingCache.new.key(model, Query.new("angry"), tenant_key: "1")

    replace_label(model, sentiment.call("how the author feels", "Unhappy, frustrated, or angry"))

    assert_equal fingerprint, model.truffler_definition.label(:sentiment).supplied_fingerprint("1")
    assert_equal [ fingerprint ], Label.where(record_id: records.map(&:id), label_key: "sentiment:negative").distinct.pluck(:fingerprint)
    assert_equal 0, Backfill.status(model)[:stale]
    assert_not_equal key, Truffler::Search::EncodingCache.new.key(model, Query.new("angry"), tenant_key: "1")

    replace_label(model, LabelDefinition.new(:sentiment, :choice, from: ->(record) { record.sentiment },
      options: %w[positive negative neutral]))
    assert_not_equal fingerprint, model.truffler_definition.label(:sentiment).supplied_fingerprint("1")
  end
end
