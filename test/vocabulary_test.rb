require "test_helper"

class VocabularyTest < Truffler::TestCase
  def model_with(question:, options: %w[a b])
    Class.new(ActiveRecord::Base) do
      self.table_name = "emails"
      define_singleton_method(:name) { "VocabEmail" }
      include Truffler::Model
      truffler do
        reads :subject
        label :needs_action, :noul, question: question
        label :folder, :choice, question: "Which folder?", options: options
      end
    end.truffler_definition
  end

  test "rewording one question changes its fingerprint and the version only" do
    before = Truffler::Vocabulary.new(model_with(question: "Needs action?"))
    after = Truffler::Vocabulary.new(model_with(question: "Does this need a reply?"))

    assert_not_equal before.fingerprint(:needs_action), after.fingerprint(:needs_action)
    assert_equal before.fingerprint(:folder), after.fingerprint(:folder)
    assert_not_equal before.version, after.version
  end

  test "fingerprints are stable for the same declaration" do
    assert_equal Truffler::Vocabulary.new(model_with(question: "Q")).fingerprints,
      Truffler::Vocabulary.new(model_with(question: "Q")).fingerprints
  end

  test "changing the model pin changes every fingerprint" do
    definition = model_with(question: "Q")
    latest = Truffler::Vocabulary.new(definition).fingerprints
    Truffler.config.model = "jev-1.13"
    pinned = Truffler::Vocabulary.new(definition).fingerprints

    latest.each_key { |key| assert_not_equal latest[key], pinned[key], key }
  end

  test "per-tenant options yield different fingerprints per tenant" do
    definition = model_with(question: "Q", options: ->(tenant) { tenant == "1" ? %w[work home] : %w[school] })
    vocabulary = Truffler::Vocabulary.new(definition)

    assert_not_equal vocabulary.fingerprint(:folder, tenant_key: "1"), vocabulary.fingerprint(:folder, tenant_key: "2")
    assert_equal vocabulary.fingerprint(:needs_action, tenant_key: "1"), vocabulary.fingerprint(:needs_action, tenant_key: "2")
    assert_not_equal vocabulary.version(tenant_key: "1"), vocabulary.version(tenant_key: "2")
  end

  test "the definition exposes its current vocabulary" do
    assert_equal Truffler::Vocabulary.new(Email.truffler_definition).version, Email.truffler_definition.vocabulary.version
  end
end
