require "test_helper"

module HappyProducts
  OPTIONS = { "cora" => "Cora" } # rubocop:disable Style/MutableConstant
end

class HappyLedgerEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject
    label :product, :choice, from: ->(email) { email.sender_name }, options: ->(_tenant_key) { HappyProducts::OPTIONS.dup }
    label :urgent, :noul, question: "Is this urgent?"
  end
end

class LedgerVersionTest < Truffler::TestCase
  Label = Truffler::Records::Label
  Spend = Truffler::Records::BackfillSpend
  Backfill = Truffler::Labeling::Backfill

  setup do
    @fake = Truffler::Clients::Fake.new.answer(:urgent, 0.8)
    Truffler.config.client = @fake
    Truffler.config.cost_per_million_tokens = 1_000.0
    HappyProducts::OPTIONS.replace("cora" => "Cora")
  end

  teardown do
    HappyProducts::OPTIONS.replace("cora" => "Cora")
  end

  def backfilled_emails
    emails = 2.times.map { HappyLedgerEmail.create!(account_id: 1, subject: "Refund", sender_name: "cora") }
    Truffler::Records::RecordState.delete_all
    clear_enqueued_jobs
    Backfill.new(HappyLedgerEmail).run
    emails
  end

  def rows(key)
    Label.where(record_type: "HappyLedgerEmail", label_key: key).order(:record_id).pluck(:record_id, :fingerprint, :labeled_at)
  end

  test "0.1.6: adding an option to a supplied label keeps the spend ledger, asks Jev nothing, and rewrites only that label" do
    backfilled_emails
    ledger = Spend.sole
    assert_operator ledger.spent_usd, :>, 0
    calls = @fake.calls.size
    urgent = rows("urgent")
    product = rows("product:cora")

    HappyProducts::OPTIONS["jev"] = "Jev"
    result = travel(1.minute) { Backfill.new(HappyLedgerEmail).run }

    assert_equal :complete, result.status
    assert_equal 0, result.requests
    assert_equal calls, @fake.calls.size
    assert_equal [ [ ledger.id, ledger.spent_usd, ledger.requests ] ], Spend.pluck(:id, :spent_usd, :requests)
    assert_equal urgent, rows("urgent")
    assert_not_equal product.map { |row| row[1] }, rows("product:cora").map { |row| row[1] }
    assert_equal 0, Backfill.status(HappyLedgerEmail)[:stale]
  end

  test "0.1.6: changing an asked label's question starts a new spend ledger" do
    backfilled_emails
    urgent = HappyLedgerEmail.truffler_definition.label(:urgent)
    calls = @fake.calls.size

    urgent.instance_variable_set(:@instructions, "Is this time-critical?")
    result = Backfill.new(HappyLedgerEmail).run

    assert_equal 1, result.requests
    assert_equal calls + 1, @fake.calls.size
    assert_equal 2, Spend.count
  ensure
    urgent&.instance_variable_set(:@instructions, "Is this urgent?")
  end

  test "0.1.6: a ledger row keyed by the pre-0.1.6 vocabulary version is adopted, not reset" do
    HappyLedgerEmail.create!(account_id: 1, subject: "Refund", sender_name: "cora")
    Truffler::Records::RecordState.delete_all
    clear_enqueued_jobs
    legacy = HappyLedgerEmail.truffler_definition.vocabulary.version(tenant_key: "1", all_users: true)
    old = Spend.create!(record_type: "HappyLedgerEmail", tenant_key: "1", vocabulary_version: legacy, spent_usd: 1.25, requests: 4)

    assert_equal old.id, Backfill.spend(HappyLedgerEmail, tenant_key: "1").id
    Backfill.new(HappyLedgerEmail).run

    assert_equal [ old.id ], Spend.pluck(:id)
    assert_equal Backfill.ledger_version(HappyLedgerEmail, "1"), old.reload.vocabulary_version
    assert_operator old.spent_usd, :>, 1.25
    assert_equal 5, old.requests
  end

  test "0.1.6: without supplied labels the ledger version is the vocabulary version, so existing rows stay keyed" do
    vocabulary = Email.truffler_definition.vocabulary

    assert_equal vocabulary.version(tenant_key: "1", all_users: true), vocabulary.ledger_version(tenant_key: "1", all_users: true)
  end
end
