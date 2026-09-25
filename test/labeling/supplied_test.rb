require "test_helper"

class SuppliedLabelsTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState
  LabelDefinition = Truffler::LabelDefinition

  # Fails the test on any budget slot: supplied labels never take one.
  class NoBudget
    def acquire(**)
      raise "supplied labels must not take a Jev budget slot"
    end
  end

  setup do
    @fake = Truffler::Clients::Fake.new
    @fake.answer(:needs_reply, 0.9)
    Truffler.config.client = @fake
    @supplied = SuppliedFeedback.truffler_definition
    @mixed = MixedFeedback.truffler_definition
  end

  teardown do
    SuppliedFeedback.truffler_definition = @supplied
    MixedFeedback.truffler_definition = @mixed
  end

  def define_model(name, &block)
    Class.new(ActiveRecord::Base) do
      self.table_name = "feedbacks"
      define_singleton_method(:name) { name }
      include Truffler::Model
      class_eval(&block)
    end
  end

  def feedback!(model = SuppliedFeedback, account_id: 1, body: "The export broke again", **attributes)
    model.create!(account_id: account_id, body: body, **attributes)
  end

  def flush
    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)
  end

  def label(model, budget: Truffler::Budget.new)
    states = Truffler::Labeling::Queue.new(model).claim("1", priority: :live, limit: 10)
    Truffler::Labeling::Labeler.new(model, budget: budget).label(states, priority: :live)
  end

  def labels_of(record)
    Label.where(record_type: record.class.polymorphic_name, record_id: record.id).order(:label_key).pluck(:label_key, :value).to_h
  end

  def jev_calls(&block)
    capture_notifications("truffler.jev_call", &block)
  end

  def replace_label(model, label)
    definition = model.truffler_definition
    replaced = definition.dup
    replaced.instance_variable_set(:@labels, definition.labels.merge(label.key => label))
    model.truffler_definition = replaced
  end

  # DSL

  test "a supplied label needs no question, and its description falls back to the key" do
    label = LabelDefinition.new(:anger, :noul, from: ->(record) { record.anger })

    assert label.supplied?
    assert_equal "anger", label.description
    assert_equal "the feedback's overall sentiment", @supplied.label(:sentiment).description
    assert_equal "Does this feedback ask for a reply?", @mixed.label(:needs_reply).description
    assert_not @mixed.label(:needs_reply).supplied?
  end

  test "an asked label still needs a question" do
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:anger, :noul) }
  end

  test "from: must be callable, and watch: and version: need from:" do
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:anger, :noul, from: :anger) }
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:anger, :noul, question: "Angry?", watch: [ :anger ]) }
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:anger, :noul, question: "Angry?", version: 2) }
  end

  test "supplied choice and score labels still need options and a legend" do
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:tone, :choice, from: ->(_) { }) }
    assert_raises(Truffler::DefinitionError) { LabelDefinition.new(:level, :score, from: ->(_) { }) }
  end

  test "watched columns must exist" do
    error = assert_raises(Truffler::DefinitionError) do
      define_model("BadWatch") { truffler { reads :body; label :anger, :noul, from: ->(record) { record.anger }, watch: [ :fury ] } }
    end
    assert_match(/fury/, error.message)
  end

  # Storage

  test "stores each type in the shape Jev answers are normalized to, with the supplied fingerprint" do
    record = feedback!(sentiment: "negative", anger: 0.8, actionability: 1)

    label(SuppliedFeedback, budget: NoBudget.new)

    assert_equal({ "actionability" => 0.5, "anger" => 0.8, "sentiment:negative" => 1.0, "sentiment:neutral" => 0.0,
                   "sentiment:positive" => 0.0 }, labels_of(record))
    fingerprints = @supplied.vocabulary.fingerprints(tenant_key: "1")
    assert_equal fingerprints["sentiment"], Label.find_by!(label_key: "sentiment:neutral").fingerprint
    assert_equal @supplied.label(:anger).supplied_fingerprint("1"), fingerprints["anger"]
    assert_equal [ "labeled", @supplied.vocabulary.version(tenant_key: "1") ], State.pluck(:status, :vocabulary_version).sole
  end

  test "a choice may be answered with probabilities and a noul with true or false" do
    define = lambda do |sentiment, anger|
      define_model("Shapes") do
        truffler do
          tenant :account_id
          reads :body
          label :sentiment, :choice, options: %w[positive negative], from: ->(_) { sentiment }
          label :anger, :noul, from: ->(_) { anger }
        end
      end
    end
    model = define.call({ negative: 0.7, "positive" => 0.3 }, true)
    record = feedback!(model)

    label(model, budget: NoBudget.new)

    assert_equal({ "anger" => 1.0, "sentiment:negative" => 0.7, "sentiment:positive" => 0.3 }, labels_of(record))
  end

  test "a nil answer stores nothing, and clears a value stored before" do
    record = feedback!(sentiment: "positive")
    label(SuppliedFeedback, budget: NoBudget.new)
    assert_equal [ "sentiment:negative", "sentiment:neutral", "sentiment:positive" ], labels_of(record).keys

    record.update_column(:sentiment, nil)
    record.truffler_refresh_labels!

    assert_empty labels_of(record)
    assert_equal "labeled", State.sole.status
  end

  test "an answer out of shape is instrumented and skipped, leaving other labels written" do
    record = feedback!(sentiment: "furious", anger: 0.4)

    payloads = capture_notifications("truffler.supplied_label_failed") { label(SuppliedFeedback, budget: NoBudget.new) }

    assert_equal({ "anger" => 0.4 }, labels_of(record))
    assert_equal [ "sentiment" ], payloads.map { |payload| payload[:label_key] }
    assert_equal "Truffler::InvalidSuppliedAnswer", payloads.sole[:error_class]
  end

  # Jev

  test "a model whose labels are all supplied makes no Jev call and records no spend" do
    feedback!(sentiment: "neutral", anger: 0.1, actionability: 2)

    calls = jev_calls { flush }

    assert_empty calls
    assert_empty @fake.calls
    assert_equal "labeled", State.sole.status
    assert_equal 5, Label.count
  end

  test "the labeler reports zero requests and zero cost when only supplied labels are stale" do
    record = feedback!(MixedFeedback, sentiment: "positive")
    flush
    assert_equal 1, @fake.calls.size

    record.update!(sentiment: "negative")
    result = nil
    calls = jev_calls { result = label(MixedFeedback, budget: NoBudget.new) }

    assert_empty calls
    assert_equal 1, @fake.calls.size
    assert_equal [ 0, 0.0 ], [ result.requests, result.cost ]
    assert_in_delta 1.0, labels_of(record)["sentiment:negative"]
  end

  test "a mixed model asks Jev only its asked labels" do
    record = feedback!(MixedFeedback, sentiment: "negative")

    flush

    assert_equal %w[r001__needs_reply], @fake.calls.sole[:questions].keys
    assert_equal({ "needs_reply" => 0.9, "sentiment:negative" => 1.0, "sentiment:neutral" => 0.0, "sentiment:positive" => 0.0 },
      labels_of(record))
  end

  test "a Jev outage still writes supplied labels" do
    record = feedback!(MixedFeedback, sentiment: "negative")
    @fake.fail_with(Truffler::Test::HttpError.new(503, "Service Unavailable"))

    flush

    assert_equal({ "sentiment:negative" => 1.0, "sentiment:neutral" => 0.0, "sentiment:positive" => 0.0 }, labels_of(record))
    assert_equal "pending", State.sole.status
    vector = Truffler::Embeddings::LabelVector.new(MixedFeedback).read(record)
    assert_in_delta 1.0, vector["sentiment:negative"]
  end

  # Refresh

  test "a watched column change refreshes the label, and the old value serves until it is rewritten" do
    record = feedback!(sentiment: "positive", anger: 0.2)
    flush

    record.update!(sentiment: "negative")

    assert_in_delta 1.0, labels_of(record)["sentiment:positive"]
    assert_equal [ "" ], Label.where(label_key: "sentiment:positive").pluck(:fingerprint)
    assert_equal @supplied.vocabulary.fingerprints(tenant_key: "1")["anger"], Label.find_by!(label_key: "anger").fingerprint
    assert_enqueued_jobs 1, only: Truffler::Jobs::LabelFlushJob

    calls = jev_calls { flush }

    assert_empty calls
    assert_in_delta 1.0, labels_of(record)["sentiment:negative"]
    assert_in_delta 0.0, labels_of(record)["sentiment:positive"]
  end

  test "an unwatched column change does not relabel" do
    record = feedback!(sentiment: "positive")
    flush

    record.update!(author_role: "admin")

    assert_no_enqueued_jobs only: Truffler::Jobs::LabelFlushJob
  end

  test "truffler_refresh_labels! writes supplied labels now, without Jev" do
    record = feedback!(MixedFeedback)
    flush
    assert_equal [ "needs_reply" ], labels_of(record).keys
    calls = @fake.calls.size

    record.update_column(:sentiment, "neutral")
    assert_same record, record.truffler_refresh_labels!

    assert_equal calls, @fake.calls.size
    assert_in_delta 1.0, labels_of(record)["sentiment:neutral"]
    assert_in_delta 0.9, labels_of(record)["needs_reply"]
    assert_in_delta 1.0, Truffler::Embeddings::LabelVector.new(MixedFeedback).read(record)["sentiment:neutral"]
  end

  test "truffler_refresh_labels! on a model without supplied labels does nothing" do
    email = Email.create!(account_id: 1, subject: "Hi", body: "There")

    assert_same email, email.truffler_refresh_labels!
    assert_equal 0, Label.count
  end

  # Backfill and vocabulary

  test "a version bump changes the vocabulary, and the backfill rewrites only supplied labels at no cost" do
    records = Array.new(3) { feedback!(MixedFeedback, sentiment: "positive") }
    flush
    before = @mixed.vocabulary.version(tenant_key: "1")
    calls = @fake.calls.size

    replace_label(MixedFeedback, LabelDefinition.new(:sentiment, :choice, options: %w[positive neutral negative],
      from: ->(record) { record.sentiment }, version: 2))
    assert_not_equal before, MixedFeedback.truffler_definition.vocabulary.version(tenant_key: "1")

    result = Truffler::Labeling::Backfill.new(MixedFeedback, spend_cap: 0.0).run

    assert_equal [ :complete, 3, 0, 0.0 ], [ result.status, result.labeled, result.requests, result.cost ]
    assert_equal calls, @fake.calls.size
    fingerprint = MixedFeedback.truffler_definition.label(:sentiment).supplied_fingerprint("1")
    assert_equal [ fingerprint ], Label.where(record_id: records.map(&:id), label_key: "sentiment:positive").distinct.pluck(:fingerprint)
  end

  test "supplied fingerprints digest type, options, and version, and ignore the Jev model" do
    label = @supplied.label(:sentiment)
    other_model = Truffler::Vocabulary.new(@supplied, model: "another-model")

    assert_equal @supplied.vocabulary.fingerprints(tenant_key: "1")["sentiment"], other_model.fingerprints(tenant_key: "1")["sentiment"]
    bumped = LabelDefinition.new(:sentiment, :choice, options: %w[positive neutral negative], from: ->(_) { }, version: 2)
    assert_not_equal label.supplied_fingerprint, bumped.supplied_fingerprint
    reworded = LabelDefinition.new(:sentiment, :choice, options: %w[positive negative], from: ->(_) { })
    assert_not_equal bumped.supplied_fingerprint, reworded.supplied_fingerprint
  end

  # Search

  test "supplied labels join filters, boosts, and the label vector like asked labels" do
    angry = feedback!(sentiment: "negative", anger: 0.9, body: "Export broke")
    calm = feedback!(sentiment: "negative", anger: 0.1, body: "Export slow")
    happy = feedback!(sentiment: "positive", anger: 0.0, body: "Export works")
    flush

    cache_encoding!(SuppliedFeedback, "angry negative feedback", filters: { "sentiment:negative" => 0.5 },
      boosts: { "anger" => 2.0 }, intent_vector: { "anger" => 2.0 }, keyword_tokens: [])
    ids = search(SuppliedFeedback, "angry negative feedback").records.map(&:id)

    assert_equal [ angry.id, calm.id ], ids
    assert_not_includes ids, happy.id
    vectors = Truffler::Embeddings::LabelVector.new(SuppliedFeedback)
    assert_equal %w[actionability anger sentiment:negative sentiment:neutral sentiment:positive], vectors.keys("1")
    assert_in_delta 0.9, vectors.read(angry)["anger"]
  end

  test "query encoding asks intent questions about supplied labels using their description" do
    request = Truffler::QueryEncoding::Encoder.new.request(SuppliedFeedback, Truffler::Search::Query.new("angry customers"),
      tenant_key: "1")

    assert_includes request.questions.keys, "intent__sentiment"
    assert_includes request.questions.keys, "option__sentiment"
    assert_includes request.questions.keys, "intent__anger"
    assert_includes request.questions["intent__sentiment"]["instructions"], "the feedback's overall sentiment"
    assert_includes request.questions["intent__anger"]["instructions"], %("anger" (anger))
  end

  test "a failed supplied answer leaves the record pending at backfill priority, and backfill retries it for free" do
    record = feedback!(sentiment: "furious", anger: 0.4)
    label(SuppliedFeedback, budget: NoBudget.new)

    state = Truffler::Records::RecordState.find_by!(record_id: record.id)
    assert_equal [ "pending", "backfill", 1, "Truffler::SuppliedLabelFailed" ],
      [ state.status, state.priority, state.attempts, state.last_error_class ]

    record.update_columns(sentiment: "negative")
    calls = jev_calls { Truffler::Labeling::Backfill.new(SuppliedFeedback).run }
    assert_empty calls
    assert_equal 1.0, labels_of(record)["sentiment:negative"]
    assert_equal "labeled", state.reload.status
  end

  test "a supplied answer that keeps failing ends failed after max_attempts" do
    Truffler.config.max_attempts = 2
    record = feedback!(sentiment: "furious", anger: 0.4)
    label(SuppliedFeedback, budget: NoBudget.new)
    Truffler::Labeling::Backfill.new(SuppliedFeedback).run

    assert_equal [ "failed", 2 ], Truffler::Records::RecordState.find_by!(record_id: record.id).then { |s| [ s.status, s.attempts ] }
  end
end
