require "test_helper"

class LensIntegrationTest < Truffler::TestCase
  include Truffler::Test::LensHelpers
  include Truffler::Test::SearchHelpers

  Lenses = Truffler::Lenses
  Lens = Truffler::Lenses::Lens
  Scope = Truffler::Lenses::Scope
  Label = Truffler::Records::Label

  def vocabulary
    FeedMessage.truffler_definition.vocabulary
  end

  def label_claimed(model = FeedMessage, tenant_key = "1")
    states = Truffler::Labeling::Queue.new(model).claim(tenant_key, priority: :live, limit: 50)
    Truffler::Labeling::Labeler.new(model).label(states, priority: :live)
  end

  def answer_lens_language(lens)
    @jev.answer(lens.labels.fetch("lens:#{lens.id}:language").question_key) do |tag, state|
      state.dig("records", tag, "body").to_s.include?("Hallo") ? "dutch" : "other"
    end
  end

  def lens_rows(record, lens)
    Label.where(record_id: record.id).where("label_key LIKE ?", "lens:#{lens.id}:%").pluck(:label_key, :value).to_h
  end

  test "activating a lens bumps only its scope's vocabulary version, and a model without lenses keeps its version" do
    declared = vocabulary.fingerprints(tenant_key: "1")
    before = vocabulary.version(tenant_key: "1")
    assert_equal Truffler::Canonical.digest(declared), before
    assert_equal declared.keys, vocabulary.labels_for(tenant_key: "1").keys

    lens = dutch_lens
    assert_enqueued_with(job: Truffler::Jobs::LensBackfillJob, args: [ lens.id ])

    key = "lens:#{lens.id}:language"
    assert_not_equal before, vocabulary.version(tenant_key: "1")
    assert_equal before, vocabulary.version(tenant_key: "2")
    assert_equal declared.merge(key => Lenses.fingerprint(lens.storage_questions[key])), vocabulary.fingerprints(tenant_key: "1")
    assert_equal [ "sentiment", "relevant", key ], vocabulary.labels_for(tenant_key: "1").keys
    assert_equal lens.storage_questions[key], vocabulary.labels_for(tenant_key: "1")[key].question
  end

  test "a record labeled after activation gets lens rows, a longer label vector, and charges the lens" do
    lens = dutch_lens
    answer_lens_language(lens)
    message = feed_message("Hallo allemaal")
    shorter = Truffler::Embeddings::LabelVector.new(FeedMessage).keys("2")

    label_claimed

    key = "lens:#{lens.id}:language"
    assert_equal({ "#{key}:dutch" => 1.0, "#{key}:other" => 0.0 }, lens_rows(message, lens))
    assert_equal vocabulary.fingerprints(tenant_key: "1")[key], Label.find_by!(label_key: "#{key}:dutch").fingerprint
    vector = Truffler::Embeddings::LabelVector.new(FeedMessage).read(message)
    assert_equal shorter.size + 2, vector.size
    assert_equal 1.0, vector["#{key}:dutch"]
    assert_equal vocabulary.version(tenant_key: "1", all_users: true),
      Truffler::Records::RecordState.find_by!(record_id: message.id).vocabulary_version
    assert_operator lens.reload.spent_usd, :>, 0
    question_ids = @jev.calls.last[:questions].keys
    assert_includes question_ids, "r001__lens#{lens.id}__language"
    assert(question_ids.all? { |id| Truffler::Questions.valid_id?(id) })
  end

  test "records of another tenant never get a tenant lens's questions" do
    dutch_lens
    other = feed_message("Hallo", account: 2)

    label_claimed(FeedMessage, "2")

    assert_empty Label.where(record_id: other.id).where("label_key LIKE 'lens:%'")
  end

  test "a lens at its spend cap stops being asked in live labeling" do
    lens = dutch_lens
    lens.update!(spend_cap_usd: 0.0001, spent_usd: 0.0001)
    message = feed_message("Hallo")

    label_claimed

    assert_empty lens_rows(message, lens)
    assert_equal({}, @jev.calls.last[:questions].select { |id, _| id.include?("lens") })
  end

  test "backfill labels newest records first by arrival and stops at the lens spend cap with spent_usd recorded" do
    messages = [ 3, 1, 5, 2, 4 ].map { |hours_ago| feed_message("Hallo #{hours_ago}", at: hours_ago.hours.ago) }
    label_claimed
    lens = dutch_lens
    answer_lens_language(lens)
    request = Truffler::Labeling::RequestBuilder.new(FeedMessage.truffler_definition, tenant_key: "1", labels: lens.labels)
      .build([ [ messages.first, lens.labels.keys ] ]).sole
    lens.update!(spend_cap_usd: Truffler.config.cost_for(Truffler::Tokens.estimate({ state: request.state, questions: request.questions })) * 2.5)

    result = Lenses::Backfill.new(lens, batch_size: 1).run

    assert_equal :spend_cap_reached, result.status
    labeled = messages.select { |message| lens_rows(message, lens).any? }
    newest = messages.sort_by(&:arrived_at).reverse.first(labeled.size)
    assert_equal newest.map(&:id).sort, labeled.map(&:id).sort
    assert_operator labeled.size, :>=, 1
    assert_operator labeled.size, :<, messages.size
    assert_equal lens.reload.spent_usd, result.spent_usd
    assert_operator result.spent_usd, :>, 0
    assert(@jev.calls.drop(1).all? { |call| call[:questions].keys.all? { |id| id.include?("lens#{lens.id}__") } })
  end

  test "the backfill job relabels everything in scope when the cap allows and records spend" do
    messages = Array.new(3) { |index| feed_message("Hallo #{index}", at: index.hours.ago) }
    feed_message("Hallo", account: 2)
    label_claimed
    lens = dutch_lens
    answer_lens_language(lens)

    perform_enqueued_jobs(only: Truffler::Jobs::LensBackfillJob)

    assert(messages.all? { |message| lens_rows(message, lens).size == 2 })
    assert_equal 3, Label.where("label_key LIKE ?", "lens:#{lens.id}:%").distinct.count(:record_id)
    assert_operator lens.reload.spent_usd, :>, 0
  end

  test "an expired lens drops out of the vocabulary and backfill while its stored labels remain" do
    before = vocabulary.version(tenant_key: "1")
    lens = dutch_lens
    answer_lens_language(lens)
    message = feed_message("Hallo")
    label_claimed

    travel_to(2.months.from_now) { Lens.expire_unused! }

    assert_equal before, vocabulary.version(tenant_key: "1")
    assert_equal FeedMessage.truffler_definition.label_keys, vocabulary.labels_for(tenant_key: "1").keys
    assert_equal 2, lens_rows(message, lens).size
    assert_equal :inactive, Lenses::Backfill.new(lens.reload).run.status
  end

  test "each_user lenses are labeled per record but only the owner's searches use them" do
    Truffler.config.lenses.creators = :each_user
    Truffler.config.lenses.authorize_lens = ->(_user, _scope) { true }
    alice = member(2)
    lens = dutch_lens(scope: Scope.user("1", alice.id), by: alice)
    answer_lens_language(lens)
    dutch = feed_message("Hallo", at: 2.hours.ago)
    english = feed_message("Hello", at: 1.hour.ago)
    label_claimed
    key = "lens:#{lens.id}:language:dutch"
    assert_equal 1.0, Label.find_by!(record_id: dutch.id, label_key: key).value

    assert_not_equal vocabulary.version(tenant_key: "1", user_key: "2"), vocabulary.version(tenant_key: "1", user_key: "3")
    assert_includes vocabulary.labels_for(tenant_key: "1", user_key: "2").keys, "lens:#{lens.id}:language"
    assert_not_includes vocabulary.labels_for(tenant_key: "1", user_key: "3").keys, "lens:#{lens.id}:language"

    cache = Truffler::Search::EncodingCache.new
    encoding = Truffler::Search::Encoding.new(boosts: { key => 1.0 }, keyword_tokens: [])
    cache.write(FeedMessage, "dutch messages", encoding, tenant_key: "1", user_key: "2")
    alice_result = FeedMessage.truffler("dutch messages", tenant: 1, scope: FeedMessage.all, user: "2")
    assert_equal [ dutch.id, english.id ], alice_result.records.map(&:id)
    assert_equal({ key => 1.0 }, alice_result.encoding.intent_vector)
    assert_equal 1, lens.reload.usage_count

    assert_nil cache.read(FeedMessage, "dutch messages", tenant_key: "1", user_key: "3")
    cache.write(FeedMessage, "dutch messages", encoding, tenant_key: "1", user_key: "3")
    bob_result = FeedMessage.truffler("dutch messages", tenant: 1, scope: FeedMessage.all, user: "3")
    assert_empty bob_result.encoding.intent_vector
    assert_equal [ english.id, dutch.id ], bob_result.records.map(&:id)
  end

  test "personal lenses key Active Record users the way keystroke search hands them to the encoding hook" do
    user = FeedMessage.create!(account_id: 1, body: "x", arrived_at: Time.current)

    assert_equal Truffler::Search::Keystroke.user_key(user), Truffler.config.lenses.key_for(user)
    assert_equal Truffler.config.lenses.key_for(user), Truffler.config.lenses.key_for(Truffler.config.lenses.key_for(user))
  end

  test "activating version 2 keeps version 1 values serving until records are relabeled" do
    lens = dutch_lens
    answer_lens_language(lens)
    old = feed_message("Hallo", at: 2.hours.ago)
    label_claimed
    v1_fingerprint = Label.find_by!(record_id: old.id, label_key: "lens:#{lens.id}:language:dutch").fingerprint

    @generator.draft(/dutch/i, name: "Happy Dutch speakers", reuse: [ "sentiment" ], questions: [
      DUTCH_QUESTION.merge(options: %w[dutch flemish other]), { key: "formal", type: "noul", instructions: "Is the message formal?" }
    ])
    lens.regenerate(by: admin)
    Lenses::Activator.activate(lens.reload, by: admin)
    key = "lens:#{lens.id}:language:dutch"
    assert_not_equal v1_fingerprint, vocabulary.fingerprints(tenant_key: "1", all_users: true)["lens:#{lens.id}:language"]

    cache_encoding!(FeedMessage, "dutch", tenant: "1", boosts: { key => 1.0 }, keyword_tokens: [])
    feed_message("Hello", at: 1.hour.ago)
    served = search(FeedMessage, "dutch")
    assert_equal old.id, served.records.first.id
    assert_equal v1_fingerprint, Label.find_by!(record_id: old.id, label_key: key).fingerprint

    @jev.answer(lens.reload.labels.fetch("lens:#{lens.id}:formal").question_key, 0.9)
    Lenses::Backfill.new(lens).run
    assert_not_equal v1_fingerprint, Label.find_by!(record_id: old.id, label_key: key).fingerprint
    assert_equal 0.9, Label.find_by!(record_id: old.id, label_key: "lens:#{lens.id}:formal").value
    assert_equal 1.0, Label.find_by!(record_id: old.id, label_key: key).value
  end

  test "with embeddings on, a query using a lens ranks by the blended label and text score" do
    Truffler.config.vector_store = :ruby
    Truffler.config.lenses.authorize_lens = ->(_user, _scope) { true }
    @generator.draft(/recipes/i, name: "Recipes", questions: [ { key: "recipe", type: "noul", instructions: "Is this a recipe?" } ])
    draft = Lenses::Drafter.draft("recipes", model: RecallNote, scope: Scope.tenant("1"))
    lens = Lenses::Activator.activate(draft, by: admin)
    key = "lens:#{lens.id}:recipe"
    store = Truffler::Embeddings::VectorStore.for(RecallNote)
    recipe = label!(RecallNote.create!(account_id: 1, title: "Soup"), key => 0.9)
    near = label!(RecallNote.create!(account_id: 1, title: "Stew"), key => 0.6)
    far = label!(RecallNote.create!(account_id: 1, title: "Taxes"), key => 0.1)
    store.write(RecallNote, recipe, [ 0.0, 1.0, 0.0 ], fingerprint: "fp")
    store.write(RecallNote, near, [ 1.0, 0.0, 0.0 ], fingerprint: "fp")
    store.write(RecallNote, far, [ 0.9, 0.1, 0.0 ], fingerprint: "fp")
    cache_encoding!(RecallNote, "recipes", intent_vector: { key => 1.0 }, keyword_tokens: [])
    Truffler::Search::EncodingCache.new.write_vector(RecallNote, "recipes", [ 1.0, 0.0, 0.0 ], tenant_key: "1")

    label_only = search(RecallNote, "recipes", weights: { text: 0.0 })
    blended = search(RecallNote, "recipes", weights: { text: 1.0 })

    assert_equal [ recipe.id, near.id, far.id ], label_only.records.map(&:id)
    assert_equal near.id, blended.records.first.id
    assert_includes blended.sources, :vector
    assert_includes blended.sources, :labels
  end

  test "query encoding asks about visible lens dimensions and boosts them into the intent vector" do
    lens = dutch_lens
    key = "lens:#{lens.id}:language"
    encoder = Truffler::QueryEncoding::Encoder.new
    query = Truffler::Search::Query.new("dutch speakers")

    request = encoder.request(FeedMessage, query, tenant_key: "1")
    assert_includes request.questions.keys, "intent__lens#{lens.id}__language"
    assert_includes request.questions.keys, "option__lens#{lens.id}__language"
    assert_not_includes encoder.request(FeedMessage, query, tenant_key: "2").questions.keys, "intent__lens#{lens.id}__language"

    answers = Truffler::Answers.new(request.questions.keys.to_h do |id|
      value = { "intent__lens#{lens.id}__language" => "boost", "option__lens#{lens.id}__language" => "dutch" }[id]
      value ||= id.start_with?("token__") ? "keyword" : (id.start_with?("option__") ? "none" : "ignore")
      [ id, { "type" => "choice", "choice" => value, "probabilities" => { value => 1.0 } } ]
    end)
    encoding = encoder.encoding_for(FeedMessage, request, answers, tenant_key: "1")
    assert_equal [ "#{key}:dutch" ], encoding.intent_vector.keys
  end

  test "a Smart run finds the searcher's personal-lens encoding and applies its filter" do
    Truffler.config.lenses.creators = :each_user
    Truffler.config.lenses.authorize_lens = ->(_user, _scope) { true }
    Truffler.config.encoding_deadline = 0
    alice = member(2)
    lens = dutch_lens(scope: Scope.user("1", alice.id), by: alice)
    answer_lens_language(lens)
    feed_message("Hallo", at: 2.hours.ago)
    feed_message("Hello", at: 1.hour.ago)
    label_claimed
    key = "lens:#{lens.id}:language:dutch"
    encoding = Truffler::Search::Encoding.new(filters: { key => 0.5 }, keyword_tokens: [])
    Truffler::Search::EncodingCache.new.write(FeedMessage, "dutch messages", encoding, tenant_key: "1", user_key: "2")

    run = FeedMessage.jev_smart_search("dutch messages", tenant: 1, scope: FeedMessage.all, user: "2")
    perform_enqueued_jobs(only: Truffler::Jobs::SmartSearchJob)

    applied = Truffler::SmartSearch::Run.load(run.id).applied_filters
    assert_includes applied.map { |filter| filter.is_a?(Hash) ? (filter[:key] || filter["key"]) : filter }.flatten.map(&:to_s), key
  end

  test "lens chips keep the lens label and removing one lens chip keeps the others" do
    split = Truffler::Search::Encoding.split_key("lens:42:language:dutch")
    assert_equal [ "lens:42:language", "dutch" ], split
    assert_equal [ "category", "billing" ], Truffler::Search::Encoding.split_key("category:billing")
    assert_equal [ "urgent" ], Truffler::Search::Encoding.split_key("urgent")

    encoding = Truffler::Search::Encoding.new(filters: { "lens:42:language:dutch" => 0.5, "lens:7:tone:warm" => 0.5 }, keyword_tokens: [])
    assert_equal [ "lens:7:tone:warm" ], encoding.without([ "lens:42:language" ]).filters.keys

    chip = Truffler::Search::Result.allocate.send(:chip, "lens:42:language:dutch", :filter)
    assert_equal "lens:42:language", chip[:label]
    assert_equal "Language: dutch", chip[:name]
  end
end
