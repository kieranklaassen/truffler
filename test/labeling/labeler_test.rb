require "test_helper"

class LabelerTest < Truffler::TestCase
  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState

  setup do
    @fake = Truffler::Clients::Fake.new
    @fake.answer(:needs_action, 0.8).answer(:urgent, 0.3).answer(:category, { "billing" => 0.7, "travel" => 0.2, "other" => 0.1 })
    @fake.answer(:importance, 1)
    Truffler.config.client = @fake
  end

  def create_emails(count, account_id: 1)
    Array.new(count) { |index| Email.create!(account_id: account_id, subject: "Invoice #{index}", body: "Pay it", sender_name: "Ann") }
  end

  def claim(tenant_key = "1")
    Truffler::Labeling::Queue.new(Email).claim(tenant_key, priority: :live, limit: 10)
  end

  test "stores one row per noul, per choice option, and per score with fingerprints" do
    email = create_emails(1).sole

    result = Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)

    rows = Label.where(record_id: email.id).order(:label_key).pluck(:label_key, :value).to_h
    assert_equal({ "category:billing" => 0.7, "category:other" => 0.1, "category:travel" => 0.2,
                   "importance" => 0.5, "needs_action" => 0.8, "urgent" => 0.3 }, rows)
    fingerprints = Email.truffler_definition.vocabulary.fingerprints(tenant_key: "1")
    assert_equal fingerprints["category"], Label.find_by!(label_key: "category:travel").fingerprint
    assert_equal [ "labeled", Email.truffler_definition.vocabulary.version(tenant_key: "1") ],
      State.pluck(:status, :vocabulary_version).sole
    assert_equal 1, result.requests
    assert_operator result.cost, :>, 0
  end

  test "packs a tenant's records into one request" do
    create_emails(3)

    Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)

    assert_equal 1, @fake.calls.size
    assert_equal %w[r001 r002 r003], @fake.calls.first[:state]["records"].keys
    assert_equal 18, Label.count
  end

  test "asks only missing or stale labels" do
    email = create_emails(1).sole
    Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)
    Label.where(record_id: email.id, label_key: "urgent").update_all(fingerprint: "old")
    State.update_all(status: "pending")

    Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)

    assert_equal %w[r001__urgent], @fake.calls.last[:questions].keys
    assert_equal Email.truffler_definition.vocabulary.fingerprint(:urgent), Label.find_by!(label_key: "urgent").fingerprint
  end

  test "records with current labels are marked labeled without a Jev call" do
    create_emails(1)
    Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)
    State.update_all(status: "pending")

    Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)

    assert_equal 1, @fake.calls.size
    assert_equal "labeled", State.sole.status
  end

  test "a tenant over its live cap is demoted before any Jev call" do
    Truffler.config.tenant_live_cap = 2
    create_emails(3)

    result = Truffler::Labeling::Labeler.new(Email).label(claim, priority: :live)

    assert result.demoted
    assert_empty @fake.calls
    assert_equal 0, Label.count
  end

  test "a denied budget raises BudgetExhausted" do
    create_emails(1)
    denied = Class.new { def acquire(**) = Truffler::Budget::Decision.new(:denied, :live, :exhausted) }.new

    assert_raises(Truffler::BudgetExhausted) do
      Truffler::Labeling::Labeler.new(Email, budget: denied).label(claim, priority: :live)
    end
    assert_empty @fake.calls
  end

  test "a record edited while its labels were in flight stays pending for relabeling" do
    email = create_emails(1).sole
    states = claim
    @fake.answer(:urgent) do
      email.update!(body: "Changed while labeling")
      0.3
    end

    Truffler::Labeling::Labeler.new(Email).label(states, priority: :live)

    assert_equal "pending", Truffler::Records::RecordState.sole.status
  end

  test "states whose records were deleted are dropped" do
    email = create_emails(1).sole
    states = claim
    Email.where(id: email.id).delete_all

    Truffler::Labeling::Labeler.new(Email).label(states, priority: :live)

    assert_equal 0, State.count
    assert_empty @fake.calls
  end

  test "editing a labeled record's text relabels every question" do
    email = create_emails(1).sole
    labeler = Truffler::Labeling::Labeler.new(Email)
    labeler.label(claim, priority: :live)
    calls = @fake.calls.size
    @fake.answer(:needs_action, 0.1)

    email.update!(body: "Never mind, all sorted")
    assert_in_delta 0.8, Label.find_by!(record_id: email.id, label_key: "needs_action").value
    labeler.label(claim, priority: :live)

    assert_equal calls + 1, @fake.calls.size
    assert_in_delta 0.1, Label.find_by!(record_id: email.id, label_key: "needs_action").value
  end
end
