require "test_helper"

class SparseChoiceTest < Truffler::TestCase
  include Truffler::Test::LensHelpers
  include Truffler::Test::SearchHelpers

  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState
  Backfill = Truffler::Labeling::Backfill

  setup do
    @fake = Truffler::Clients::Fake.new
    @fake.answer(:category, { "billing" => 0.9, "travel" => 0.04, "other" => 0.06 })
    Truffler.config.client = @fake
  end

  def labeled_email(subject: "Invoice")
    email = Email.create!(account_id: 1, subject: subject, body: "Pay it", sender_name: "Ann", received_at: Time.current)
    perform_enqueued_jobs
    email
  end

  def category_rows(record)
    Label.where(record_id: record.id).where("label_key LIKE 'category:%'").pluck(:label_key, :value).sort.to_h
  end

  test "choice labels store only options at or above choice_min_probability" do
    email = labeled_email

    assert_equal({ "category:billing" => 0.9, "category:other" => 0.06 }, category_rows(email))
    assert_equal 0.05, Truffler.config.choice_min_probability
  end

  test "nil choice_min_probability stores every option" do
    Truffler.config.choice_min_probability = nil

    assert_equal %w[category:billing category:other category:travel], category_rows(labeled_email).keys
  end

  test "the argmax option is kept even when it is below the minimum" do
    Truffler.config.choice_min_probability = 0.5
    @fake.answer(:category, { "billing" => 0.3, "travel" => 0.4, "other" => 0.3 })

    assert_equal({ "category:travel" => 0.4 }, category_rows(labeled_email))
  end

  test "a sparse choice label is current, so a backfill or relabel never asks it again" do
    labeled_email
    calls = @fake.calls.size

    result = Backfill.new(Email).run
    Truffler::Labeling::Labeler.new(Email).label(Truffler::Labeling::Queue.new(Email).claim_backfill(Email.ids, "1"), priority: :backfill)

    assert_equal [ :complete, 0 ], [ result.status, result.requests ]
    assert_equal calls, @fake.calls.size
    assert_equal [ "labeled" ], State.pluck(:status)
  end

  test "a missing option reads as 0.0 in the label vector" do
    email = labeled_email

    vector = Truffler::Embeddings::LabelVector.new(Email).read(email)

    assert_equal 0.0, vector.fetch("category:travel")
    assert_in_delta 0.9, vector.fetch("category:billing"), 1e-6
  end

  test "a missing option reads as 0.0 in filters, boosts, and contributions" do
    email = labeled_email
    cache_encoding!(Email, "travel stuff", filters: { "category:travel" => 0.01 })
    cache_encoding!(Email, "billing stuff", filters: { "category:billing" => 0.5 })
    cache_encoding!(Email, "boosted", intent_vector: { "category:travel" => 1.0, "category:billing" => 1.0 })

    assert_empty search(Email, "travel stuff").records
    assert_equal [ email.id ], search(Email, "billing stuff").records.map(&:id)
    boosted = search(Email, "boosted")
    contributions = boosted.contributions(boosted.records.sole)
    assert_equal 0.0, contributions.fetch("category:travel", 0.0)
    assert_in_delta 0.9, contributions.fetch("category:billing"), 1e-9
  end

  test "supplied choice answers store only the options above the minimum" do
    feedback = SuppliedFeedback.create!(account_id: 1, body: "Great", sentiment: "positive")
    perform_enqueued_jobs

    rows = Label.where(record_id: feedback.id).where("label_key LIKE 'sentiment:%'").pluck(:label_key, :value)
    assert_equal [ [ "sentiment:positive", 1.0 ] ], rows
    Backfill.new(SuppliedFeedback).run
    assert_equal [ "labeled" ], State.where(record_id: feedback.id).pluck(:status)
  end

  test "a lens backfill treats a sparse lens choice as current and does not ask it again" do
    message = feed_message("Hallo")
    @jev.answer(:sentiment, "happy")
    perform_enqueued_jobs
    lens = dutch_lens
    @jev.answer(lens.labels.fetch("lens:#{lens.id}:language").question_key, "dutch")
    Truffler::Lenses::Backfill.new(lens).run
    asked = @jev.calls.size

    result = Truffler::Lenses::Backfill.new(lens).run

    assert_equal [ [ "lens:#{lens.id}:language:dutch", 1.0 ] ],
      Label.where(record_id: message.id).where("label_key LIKE ?", "lens:#{lens.id}:%").pluck(:label_key, :value)
    assert_equal [ :complete, 0 ], [ result.status, result.requests ]
    assert_equal asked, @jev.calls.size
  end
end
