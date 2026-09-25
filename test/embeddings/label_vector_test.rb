require "test_helper"

class LabelVectorTest < Truffler::TestCase
  Embedding = Truffler::Records::Embedding
  KEYS = %w[category:billing category:other category:travel importance needs_action urgent].freeze

  setup do
    @fake = Truffler::Clients::Fake.new
    @fake.answer(:needs_action, 0.8).answer(:urgent, 0.3).answer(:category, { "billing" => 0.7, "travel" => 0.2, "other" => 0.1 })
    @fake.answer(:importance, 1)
    Truffler.config.client = @fake
  end

  def label_emails(count = 1, account_id: 1)
    emails = Array.new(count) { |index| Email.create!(account_id: account_id, subject: "Invoice #{index}", body: "Pay it") }
    states = Truffler::Labeling::Queue.new(Email).claim(account_id.to_s, priority: :live, limit: 10)
    Truffler::Labeling::Labeler.new(Email).label(states, priority: :live)
    emails
  end

  def vectors
    Truffler::Embeddings::LabelVector.new(Email)
  end

  test "keys are the sorted storage keys with choice options expanded" do
    assert_equal KEYS, vectors.keys("1")
  end

  test "labeling writes the label vector in key order beside no text vector" do
    email = label_emails.sole

    row = Embedding.find_by!(record_type: "Email", record_id: email.id)
    assert_equal [ 0.7, 0.1, 0.2, 0.5, 0.8, 0.3 ], row.label_values.map { |value| value.round(4) }
    assert_equal Email.truffler_definition.vocabulary.version(tenant_key: "1"), row.label_vocabulary_version
    assert_equal "1", row.tenant_key
    assert_nil row.embedding
    assert_equal KEYS, vectors.read(email).keys
    assert_in_delta 0.8, vectors.read(email)["needs_action"]
  end

  test "relabeling rewrites the vector with the new values" do
    email = label_emails.sole
    @fake.answer(:urgent, 0.9)
    Truffler::Records::Label.where(record_id: email.id, label_key: "urgent").update_all(fingerprint: "old")
    Truffler::Records::RecordState.update_all(status: "pending")

    Truffler::Labeling::Labeler.new(Email).label(Truffler::Labeling::Queue.new(Email).claim("1", priority: :live, limit: 10),
      priority: :live)

    assert_in_delta 0.9, vectors.read(email)["urgent"]
  end

  test "a vocabulary change rebuilds vectors from truffler_labels without calling Jev" do
    emails = label_emails(2)
    other_tenant = label_emails(1, account_id: 2).sole
    calls = @fake.calls.size
    definition = Email.truffler_definition
    original = definition.labels.dup
    definition.add_label(Truffler::LabelDefinition.new(:angry, :noul, question: "Is the sender angry?"))

    assert_nil vectors.read(emails.first)
    assert_equal 3, vectors.rebuild
    assert_equal 0, vectors.rebuild

    assert_equal calls, @fake.calls.size
    expanded = vectors.read(emails.first)
    assert_equal [ "angry", *KEYS ], expanded.keys
    assert_equal 0.0, expanded["angry"]
    assert_in_delta 0.8, expanded["needs_action"]
    assert_equal "2", Embedding.find_by!(record_id: other_tenant.id).tenant_key
  ensure
    definition.labels.replace(original) if original
  end

  test "rebuild can be limited to one tenant" do
    label_emails(1)
    label_emails(1, account_id: 2)
    Embedding.update_all(label_vocabulary_version: "old")

    assert_equal 1, vectors.rebuild(tenant_key: "2")
    assert_equal %w[old], Embedding.where(tenant_key: "1").pluck(:label_vocabulary_version)
  end

  test "records already current still get a vector" do
    email = label_emails.sole
    Embedding.delete_all
    Truffler::Records::RecordState.update_all(status: "pending")

    Truffler::Labeling::Labeler.new(Email).label(Truffler::Labeling::Queue.new(Email).claim("1", priority: :live, limit: 10),
      priority: :live)

    assert_equal 1, @fake.calls.size
    assert_in_delta 0.8, vectors.read(email)["needs_action"]
  end

  test "writing a label vector keeps an existing text vector" do
    note = EmbeddedNote.create!(account_id: 1, title: "Hello")
    Truffler::Embeddings::RubyStore.new.write(EmbeddedNote, note, [ 1.0, 0.0 ], fingerprint: "fp")

    Truffler::Embeddings::LabelVector.new(EmbeddedNote).write([ note.id ], tenant_key: "1")

    row = Embedding.sole
    assert_equal [ 1.0, 0.0 ], row.vector
    assert_equal [ 0.0 ], row.label_values
  end

  test "destroying a record removes its vectors" do
    email = label_emails.sole

    email.destroy!

    assert_equal 0, Embedding.count
  end
end
