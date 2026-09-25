require "test_helper"

class LabelingWatchTest < Truffler::TestCase
  Label = Truffler::Records::Label

  setup do
    Truffler.config.client = @fake = Truffler::Clients::Fake.new { 0.5 }
  end

  teardown do
    self.class.send(:remove_const, :Watched) if self.class.const_defined?(:Watched, false)
  end

  # `conversation` is method-backed: saved_changes never names it, so the
  # columns it is built from are watched instead.
  def watched_model(&block)
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "feedbacks"
      include Truffler::Model

      def conversation = "#{author_role}: #{body}"
    end
    self.class.const_set(:Watched, model)
    model.truffler(&block)
    model
  end

  def declare_watched
    watched_model do
      tenant :account_id
      reads :conversation
      watch :author_role, :body
      label :churn_risk, :noul, question: "Is this customer at risk of leaving?", watch: [ :anger ]
      label :needs_reply, :noul, question: "Does this ask for a reply?"
    end
  end

  def labeled_record
    record = Watched.create!(account_id: 1, body: "Export broke", author_role: "customer", anger: 0.1)
    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)
    assert_equal %w[churn_risk needs_reply], fingerprints(record).keys
    record
  end

  def fingerprints(record)
    Label.where(record_type: record.class.polymorphic_name, record_id: record.id).order(:label_key).pluck(:label_key, :fingerprint).to_h
  end

  test "0.1.1: a model-level watched column relabels every label when a method-backed read depends on it" do
    declare_watched
    record = labeled_record
    asked = @fake.calls.size

    record.update!(author_role: "admin")

    assert_equal({ "churn_risk" => "", "needs_reply" => "" }, fingerprints(record))
    assert_enqueued_jobs 1, only: Truffler::Jobs::LabelFlushJob
    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)
    assert_equal asked + 1, @fake.calls.size
    assert_equal %w[r001__churn_risk r001__needs_reply], @fake.calls.last[:questions].keys.sort
  end

  test "0.1.1: watch: on an asked label relabels only that label" do
    declare_watched
    record = labeled_record

    record.update!(anger: 0.9)

    assert_equal "", fingerprints(record)["churn_risk"]
    assert_not_equal "", fingerprints(record)["needs_reply"]
    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)
    assert_equal %w[r001__churn_risk], @fake.calls.last[:questions].keys
  end

  test "0.1.1: a change to an unwatched column does not relabel" do
    declare_watched
    record = labeled_record

    record.update!(sentiment: "negative")

    assert_no_enqueued_jobs only: Truffler::Jobs::LabelFlushJob
  end

  test "0.1.1: watched columns must exist, and version: still needs from:" do
    error = assert_raises(Truffler::DefinitionError) { watched_model { reads :body; watch :fury } }
    assert_match(/fury/, error.message)
    self.class.send(:remove_const, :Watched)
    error = assert_raises(Truffler::DefinitionError) { watched_model { reads :body; label :risk, :noul, question: "Risk?", watch: [ :rage ] } }
    assert_match(/rage/, error.message)
    assert_raises(Truffler::DefinitionError) { Truffler::LabelDefinition.new(:risk, :noul, question: "Risk?", version: 2) }
  end
end
