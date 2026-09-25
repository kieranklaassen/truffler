require "test_helper"

class PreviewerTest < Truffler::TestCase
  include Truffler::Test::LensHelpers

  Previewer = Truffler::Lenses::Previewer

  DeniedBudget = Struct.new(:calls) do
    def acquire(**)
      Truffler::Budget::Decision.new(:denied, :encode, :exhausted)
    end

    def ceiling(_priority) = 1.0
  end

  setup do
    answer_language_by_body
  end

  def seed_feed
    base = Time.utc(2026, 9, 1)
    25.times do |i|
      body = i.even? ? "Hallo, ik ben blij #{i}" : "Hello, I am happy #{i}"
      feed_message(body, at: base + i.hours)
    end
    5.times { |i| feed_message("Hallo other tenant #{i}", account: 2, at: base + 100.hours + i.hours) }
  end

  test "a 20-record preview makes one single-tenant Jev request and returns distribution, examples, and an estimate" do
    seed_feed

    preview = Previewer.preview(dutch_draft, sample: 20)

    call = @jev.calls.sole
    assert_equal 20, call[:state]["records"].size
    assert_equal 20, call[:questions].size
    assert(call[:questions].keys.all? { |id| id.end_with?("__language") })
    newest_tenant_one = FeedMessage.where(account_id: 1).order(arrived_at: :desc).limit(20).pluck(:id)
    assert_equal newest_tenant_one, preview.sample_ids
    assert_equal "1", preview.tenant_key

    assert_equal({ "dutch" => 10, "other" => 10 }, preview.distribution["language"])
    assert_equal 5, preview.examples["language"]["dutch"].size
    assert(preview.examples["language"]["dutch"].all? { |id| FeedMessage.find(id).body.include?("Hallo") })
    assert_in_delta 1.0, preview.values[preview.examples["language"]["dutch"].first]["language:dutch"]

    estimate = preview.estimate
    assert_equal 25, estimate.records
    assert_equal 3, estimate.requests
    assert_operator estimate.cost_usd, :>, 0
    assert_operator estimate.duration_seconds, :>=, 1
    assert estimate.within_cap
    assert_operator preview.cost, :>, 0
  end

  test "preview results carry ids and numbers, never record text" do
    seed_feed

    preview = Previewer.preview(dutch_draft, sample: 5)

    assert_not_includes preview.to_h.to_s, "Hallo"
    assert_not_includes preview.to_h.to_s, "blij"
  end

  test "the preview is refused before any Jev call when it would exceed the lens spend cap" do
    seed_feed
    Truffler.config.lenses.spend_cap_usd = 0.000_000_1

    assert_raises(Truffler::LensSpendCapExceeded) { Previewer.preview(dutch_draft) }
    assert_empty @jev.calls
  end

  test "previewing a saved lens records its spend against the lens cap and refuses once the cap is spent" do
    seed_feed
    lens = dutch_lens

    preview = Previewer.preview(lens, sample: 10)
    assert_in_delta preview.cost, lens.reload.spent_usd

    lens.update!(spend_cap_usd: lens.spent_usd)
    assert_raises(Truffler::LensSpendCapExceeded) { Previewer.preview(lens.reload, sample: 10) }
    assert_equal 1, @jev.calls.size
  end

  test "an exhausted encode budget skips the preview" do
    seed_feed

    assert_raises(Truffler::BudgetExhausted) { Previewer.new(budget: DeniedBudget.new).preview(dutch_draft) }
    assert_empty @jev.calls
  end

  test "the sample shrinks to fit the per-request question limit and honors the host relation" do
    seed_feed
    Truffler.config.max_questions_per_request = 6

    preview = Previewer.preview(dutch_draft, sample: 20, relation: FeedMessage.where("body LIKE ?", "Hello%"))

    assert_equal 6, preview.sample_ids.size
    assert_equal({ "dutch" => 0, "other" => 6 }, preview.distribution["language"])
    assert_equal 12, preview.estimate.records
  end

  test "an app lens on a scoped model samples one tenant: the newest record's" do
    seed_feed

    preview = Previewer.preview(dutch_draft(scope: Truffler::Lenses::Scope.app), sample: 20)

    assert_equal "2", preview.tenant_key
    assert_equal 5, preview.sample_ids.size
    assert_equal 30, preview.estimate.records
  end

  test "comparing a regenerated version with the active one reports distribution shift and bucket changes on the same sample" do
    feed_message("Hallo daar", at: 4.hours.ago)
    feed_message("Hallo weer", at: 3.hours.ago)
    feed_message("Hello there", at: 2.hours.ago)
    feed_message("Hello again", at: 1.hour.ago)
    lens = dutch_lens
    v1_questions = Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1")

    @generator.draft(/dutch/i, reuse: [ "sentiment" ], questions: [
      { key: "language", type: "choice", instructions: "Which language is the message written in?", options: %w[dutch english other] },
      { key: "formal", type: "noul", instructions: "Is the message formal?" }
    ])
    v2 = lens.regenerate(by: admin)
    @jev.answer(:language) do |tag, state|
      body = state.dig("records", tag, "body")
      next(body.include?("Hallo") ? "dutch" : "other") if @jev.calls.size == 1

      body.include?("Hallo") ? "dutch" : "english"
    end

    comparison = Previewer.compare(v2, lens, sample: 20)

    assert_equal comparison.before.sample_ids, comparison.after.sample_ids
    assert_equal 2, @jev.calls.size
    assert_equal({ "dutch" => 0, "other" => -2, "english" => 2 }, comparison.shift["language"][:buckets])
    assert_equal 2, comparison.shift["language"][:changed]
    assert_equal 2, comparison.changed_count
    assert(comparison.changed_ids.all? { |id| FeedMessage.find(id).body.start_with?("Hello") })
    assert_equal [ "formal" ], comparison.added
    assert_empty comparison.removed

    assert_equal "draft", v2.reload.status
    assert_equal v1_questions, Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1")
  end
end
