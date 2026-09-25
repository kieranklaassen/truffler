require "test_helper"
require "minitest/mock"

class LensTest < Truffler::TestCase
  include Truffler::Test::LensHelpers

  Lenses = Truffler::Lenses
  Lens = Truffler::Lenses::Lens
  Scope = Truffler::Lenses::Scope

  def store_label(lens_key, record, value:, fingerprint:)
    Truffler::Records::Label.create!(record_type: "FeedMessage", record_id: record.id, tenant_key: "1", label_key: lens_key,
      value: value, fingerprint: fingerprint, labeled_at: Time.current)
  end

  test "the migration template creates both lens tables with a unique version number per lens" do
    connection = ActiveRecord::Base.connection

    assert connection.table_exists?(:truffler_lenses)
    assert(connection.indexes(:truffler_lens_versions).any? { |index| index.unique && index.columns == %w[lens_id number] })
  end

  test "activating a draft persists an active lens and version and exposes its questions to its scope" do
    assert_nil Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")

    lens = dutch_lens

    assert_equal "active", lens.status
    assert_equal lens.versions.sole, lens.active_version
    assert_equal "active", lens.active_version.status
    assert_equal 1, lens.active_version.number
    assert_equal [ "sentiment" ], lens.reused_keys
    assert_equal "Happy Dutch speakers", lens.name
    assert_equal "happy people who speak Dutch", lens.reload.description

    visible = Lenses.visible(FeedMessage, tenant_key: "1")
    key = "lens:#{lens.id}:language"
    assert_equal [ key ], visible.questions.keys
    assert_equal %w[dutch other], visible.questions[key]["criteria"].keys
    assert_equal({ key => Lenses.fingerprint(visible.questions[key]) }, visible.fingerprints)
    assert_equal Truffler::Canonical.digest(visible.fingerprints), visible.lens_fingerprints
    assert_equal [ lens.id ], visible.lens_ids
    assert_equal visible.questions, Lenses.visible_questions(FeedMessage, tenant_key: "1")
    assert_equal visible.lens_fingerprints, Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")
    assert_equal [ "#{key}:dutch", "#{key}:other" ], lens.storage_keys

    assert_empty Lenses.visible_questions(FeedMessage, tenant_key: "2")
    assert_empty Lenses.visible_questions(Email, tenant_key: "1")
  end

  test "an app lens is visible to every tenant and is instrumented without its description" do
    payloads = capture_notifications("truffler.lens_activated") { dutch_lens(scope: Scope.app) }

    assert_equal 1, Lenses.visible_questions(FeedMessage, tenant_key: "1").size
    assert_equal 1, Lenses.visible_questions(FeedMessage, tenant_key: "9").size
    assert_equal 1, payloads.sole[:question_count]
    assert_not_includes payloads.sole.to_s, "Dutch"
  end

  test "lens fingerprints digest every visible lens and change when another lens is activated" do
    first = dutch_lens
    before = Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")

    @generator.draft(/formal/, questions: [ { key: "formal", type: "noul", instructions: "Is the message formal?" } ])
    second = Lenses::Activator.activate(Lenses::Drafter.draft("formal", model: FeedMessage, scope: Scope.tenant("1")), by: admin)

    assert_not_equal before, Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")
    assert_equal [ "lens:#{first.id}:language", "lens:#{second.id}:formal" ], Lenses.visible_questions(FeedMessage, tenant_key: "1").keys
  end

  test "regenerating creates version 2 as a draft while search keeps using version 1" do
    lens = dutch_lens
    before = Lenses.visible(FeedMessage, tenant_key: "1")
    script_dutch({ key: "formal", type: "noul", instructions: "Is the message formal?" })

    v2 = lens.regenerate(by: admin, description: "happy people who speak Dutch formally")

    assert_equal 2, v2.number
    assert_equal "draft", v2.status
    assert_equal %w[language formal], v2.questions.keys
    assert_equal "happy people who speak Dutch formally", v2.reload.description
    assert_equal 1, lens.reload.active_version.number
    assert_equal before, Lenses.visible(FeedMessage, tenant_key: "1")
    offered = JSON.parse(@generator.calls.last[:prompt])["existing_labels"].map { |label| label["key"] }
    assert_not(offered.any? { |key| key.start_with?(Lenses.storage_prefix(lens.id)) })
  end

  test "activating version 2 marks the lens label rows stale while their stored values keep serving" do
    lens = dutch_lens
    record = feed_message("Hallo daar")
    v1_fingerprints = Lenses.visible(FeedMessage, tenant_key: "1").fingerprints
    key = "lens:#{lens.id}:language"
    store_label("#{key}:dutch", record, value: 0.9, fingerprint: v1_fingerprints[key])

    @generator.draft(/dutch/i, reuse: [ "sentiment" ], questions: [
      { key: "language", type: "choice", instructions: "Which language is the message written in?", options: %w[dutch english other] }
    ])
    v2 = lens.regenerate(by: admin)
    v1_version = Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")
    Lenses::Activator.activate(v2, by: admin)

    v2_fingerprints = Lenses.visible(FeedMessage, tenant_key: "1").fingerprints
    stored = Truffler::Records::Label.find_by!(label_key: "#{key}:dutch")
    assert_not_equal v2_fingerprints[key], stored.fingerprint
    assert_in_delta 0.9, stored.value
    assert_not_equal v1_version, Lenses.lens_fingerprints(FeedMessage, tenant_key: "1")
    assert_equal %w[retired active], lens.versions.reload.map(&:status)
    assert_equal v2, lens.reload.active_version
  end

  test "restoring version 1 makes its questions active again and history shows all three changes" do
    lens = dutch_lens
    v1_fingerprints = Lenses.visible(FeedMessage, tenant_key: "1").fingerprints
    script_dutch({ key: "formal", type: "noul", instructions: "Is the message formal?" })
    editor = Truffler::Test::LensHelpers::User.new(id: 7, admin: true)
    travel 1.hour do
      Lenses::Activator.activate(lens.regenerate(by: editor), by: editor)
    end

    travel 2.hours do
      lens.restore!(1, by: admin)
    end

    lens.reload
    assert_equal 3, lens.active_version.number
    assert_equal 1, lens.active_version.restored_from
    assert_equal v1_fingerprints, Lenses.visible(FeedMessage, tenant_key: "1").fingerprints

    history = lens.history
    assert_equal [ 1, 2, 3 ], history.map(&:number)
    assert_equal %w[retired retired active], history.map(&:status)
    assert_equal [ nil, nil, 1 ], history.map(&:restored_from)
    assert_equal [ Lenses.digest("1"), Lenses.digest("7"), Lenses.digest("1") ], history.map(&:created_by_digest)
    assert_equal [ Lenses.digest("1"), Lenses.digest("7"), Lenses.digest("1") ], history.map(&:activated_by_digest)
    assert_equal [ %w[language], %w[language formal], %w[language] ], history.map(&:label_keys)
    assert_equal history.map(&:created_at), history.map(&:created_at).sort
    assert(history.all?(&:activated_at))
  end

  test "on an encrypted model the stored lens description is ciphertext and reads back as the description" do
    @generator.draft(/phishing/, questions: [ { key: "phishing", type: "noul", instructions: "Is this note phishing?" } ])
    draft = Lenses::Drafter.draft("secret notes that look like phishing", model: SecretNote, scope: Scope.tenant("1"))

    lens = Lenses::Activator.activate(draft, by: admin)

    raw_lens = Lens.where(id: lens.id).pick(:description)
    raw_version = Lenses::Version.where(lens_id: lens.id).pick(:description)
    assert_not_includes raw_lens, "phishing"
    assert_not_includes raw_version, "phishing"
    assert_equal "secret notes that look like phishing", Lens.find(lens.id).description
    assert_equal "secret notes that look like phishing", Lenses::Version.find_by(lens_id: lens.id).description
  end

  test "on an encrypted model without AR encryption configured no description is stored" do
    draft = Lenses::Drafter.draft("secret notes about dutch", model: SecretNote, scope: Scope.tenant("1"))

    lens = Truffler::Misses.stub(:encryption_configured?, false) { Lenses::Activator.activate(draft, by: admin) }

    assert_nil Lens.where(id: lens.id).pick(:description)
    assert_nil Lenses::Version.where(lens_id: lens.id).pick(:description)
    assert_raises(Truffler::InvalidLens) { Lens.find(lens.id).regenerate(by: admin) }
  end

  test "instrumentation for drafting and activating an encrypted-model lens carries no description text" do
    payloads = capture_notifications(/truffler\.lens/) do
      draft = Lenses::Drafter.draft("notes from my accountant about taxes", model: SecretNote, scope: Scope.tenant("1"))
      Lenses::Activator.activate(draft, by: admin)
    end

    assert_equal 2, payloads.size
    assert_not_includes payloads.to_s, "accountant"
  end

  test "spend is tracked atomically against the lens cap" do
    lens = dutch_lens
    lens.update!(spend_cap_usd: 0.01)

    lens.record_spend!(0.004)
    Lens.find(lens.id).record_spend!(0.004)

    assert_in_delta 0.008, lens.reload.spent_usd
    assert_in_delta 0.002, lens.remaining_spend
    assert_not lens.spend_cap_reached?
    assert lens.would_exceed_cap?(0.003)
    lens.record_spend!(0.002)
    assert lens.spend_cap_reached?
  end

  test "a lens unused past expire_after expires and drops out of encodings while its labels remain" do
    lens = dutch_lens
    record = feed_message("Hallo")
    store_label("lens:#{lens.id}:language:dutch", record, value: 1.0, fingerprint: "x")

    travel 29.days do
      assert_equal 0, Truffler::Jobs::ExpireLensesJob.perform_now
    end
    travel 31.days do
      assert_equal 1, Truffler::Jobs::ExpireLensesJob.perform_now
    end

    assert lens.reload.expired?
    assert_empty Lenses.visible_questions(FeedMessage, tenant_key: "1")
    assert_equal 1, Truffler::Records::Label.where("label_key LIKE ?", "lens:#{lens.id}:%").count
  end

  test "recording usage counts searches and keeps a lens from expiring" do
    lens = dutch_lens

    travel 20.days do
      assert_equal 1, Lenses.record_usage([ lens.id ])
    end
    travel 40.days do
      Lens.expire_unused!
    end

    assert lens.reload.active?
    assert_equal 1, lens.usage_count
    assert_equal 0, Lenses.record_usage([])
  end

  test "promote! prints a declaration snippet that the DSL accepts with the same question" do
    script_dutch({ key: "warmth", type: "score", instructions: "How warm is the tone?", levels: %w[cold neutral warm] },
      { key: "formal", type: "noul", instructions: "Is it formal?", criteria_true: "Formal register", criteria_false: "Casual" })
    lens = Lenses::Activator.activate(Lenses::Drafter.draft("dutch", model: FeedMessage, scope: Scope.tenant("1")), by: admin)
    io = StringIO.new

    snippet = lens.promote!(io: io)

    assert_equal snippet, io.string.chomp
    definition = Truffler::Definition.new(FeedMessage)
    Truffler::Definition::DSL.new(definition).instance_eval(snippet)
    lens.questions.each { |key, question| assert_equal question, definition.label(key).question }
  end

  test "activating a proposed or regenerated lens by the lens itself uses its newest draft version" do
    lens = dutch_lens
    assert_raises(Truffler::InvalidLens) { Lenses::Activator.activate(lens, by: admin) }

    v2 = lens.regenerate(by: admin)
    Lenses::Activator.activate(lens.reload, by: admin)

    assert_equal v2, lens.reload.active_version
  end
end
