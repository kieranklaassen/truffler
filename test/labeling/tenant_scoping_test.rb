require "test_helper"
require "rake"

class TenantScopingTest < Truffler::TestCase
  Label = Truffler::Records::Label
  State = Truffler::Records::RecordState
  Spend = Truffler::Records::BackfillSpend
  Backfill = Truffler::Labeling::Backfill
  BackfillJob = Truffler::Jobs::BackfillJob
  EmbedJob = Truffler::Jobs::EmbedJob

  setup do
    @fake = Truffler::Clients::Fake.new.answer(:needs_action, 0.8).answer(:urgent, 0.9).answer(:spam, 0.1)
    Truffler.config.client = @fake
    @embedder = Truffler::Embeddings::FakeEmbedder.new
    Truffler.config.embedder = @embedder
    Truffler.config.vector_store = :ruby
  end

  def disable_tenant(disabled)
    Truffler.config.tenant_enabled = ->(_model, tenant_key) { tenant_key != disabled }
  end

  def create_email(account_id: 1)
    Email.create!(account_id: account_id, subject: "Invoice", body: "Pay it", sender_name: "Ann")
  end

  def create_note(account_id: 1, archived: false)
    TenantNote.create!(account_id: account_id, title: "Escrow", archived: archived)
  end

  def hide_states
    State.delete_all
    clear_enqueued_jobs
  end

  def labeled_accounts(model = Email)
    ids = Label.where(record_type: model.polymorphic_name).distinct.pluck(:record_id)
    model.where(id: ids).distinct.pluck(:account_id).sort
  end

  def request_cost(count, tenant_key: "1")
    records = Email.where(account_id: tenant_key).order(:id).first(count).map { |email| [ email, Email.truffler_definition.label_keys ] }
    request = Truffler::Labeling::RequestBuilder.new(Email.truffler_definition, tenant_key: tenant_key).build(records).sole
    Truffler.config.cost_for(Truffler::Tokens.estimate({ state: request.state, questions: request.questions }))
  end

  test "a disabled tenant's records get no state row, no flush, and no embedding on save" do
    disable_tenant("2")

    create_note(account_id: 2).update!(title: "Changed")
    create_email(account_id: 2)

    assert_empty State.all
    assert_no_enqueued_jobs only: [ Truffler::Jobs::LabelFlushJob, EmbedJob ]
    create_note(account_id: 1)
    assert_equal [ "1" ], State.distinct.pluck(:tenant_key)
    assert_enqueued_jobs 1, only: EmbedJob
  end

  test "index_if keeps records out of the after-commit hooks and refresh" do
    note = create_note(archived: true)

    assert_empty State.all
    assert_no_enqueued_jobs only: [ Truffler::Jobs::LabelFlushJob, EmbedJob ]
    note.update!(title: "Other")
    assert_empty State.all
  end

  test "a flush for a disabled tenant labels nothing" do
    create_email(account_id: 2)
    disable_tenant("2")

    perform_enqueued_jobs

    assert_empty @fake.calls
    assert_empty Label.all
  end

  test "the labeler drops records no longer indexable instead of labeling them" do
    note = create_note
    note.update_columns(archived: true)

    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)

    assert_empty @fake.calls
    assert_empty State.where(record_id: note.id)
  end

  test "a whole-model backfill skips disabled tenants and records outside index_scope" do
    create_email(account_id: 1)
    create_email(account_id: 2)
    kept = create_note
    create_note(archived: true)
    hide_states
    disable_tenant("2")

    assert_equal :complete, Backfill.new(Email).run.status
    assert_equal :complete, Backfill.new(TenantNote).run.status

    assert_equal [ 1 ], labeled_accounts
    assert_equal [ kept.id ], Label.where(record_type: "TenantNote").pluck(:record_id)
  end

  test "a tenant backfill pages over that tenant only, and a disabled tenant's does nothing" do
    create_email(account_id: 1)
    create_email(account_id: 2)
    hide_states

    result = Backfill.new(Email, tenant_key: "2").run

    assert_equal [ :complete, 1 ], [ result.status, result.labeled ]
    assert_equal [ 2 ], labeled_accounts
    disable_tenant("1")
    assert_equal [ :complete, 0 ], Backfill.new(Email, tenant_key: "1").run.then { |run| [ run.status, run.labeled ] }
    assert_equal [ "2" ], State.distinct.pluck(:tenant_key)
  end

  test "BackfillJob takes a tenant_key and carries it into follow-ups" do
    3.times { create_email(account_id: 1) }
    create_email(account_id: 2)
    hide_states

    BackfillJob.perform_now("Email", tenant_key: "1", max_pages: 1)
    follow_up = enqueued_jobs.find { |job| job[:job] == BackfillJob }
    assert_equal "1", follow_up[:args].last["tenant_key"] if follow_up
    perform_enqueued_jobs

    assert_equal [ 1 ], labeled_accounts
  end

  test "demoted live rows schedule a backfill for their tenant" do
    Truffler.config.tenant_live_cap = 1
    2.times { create_email(account_id: 1) }
    2.times { create_email(account_id: 2) }
    clear_enqueued_jobs

    Truffler::Jobs::LabelFlushJob.perform_now("Email", "1")
    Truffler::Jobs::LabelFlushJob.perform_now("Email", "2")

    tenants = enqueued_jobs.select { |job| job[:job] == BackfillJob }.map { |job| job[:args].last["tenant_key"] }
    assert_equal %w[1 2], tenants.sort
  end

  test "ResumeJob enqueues one BackfillJob per enabled tenant and no flush for disabled ones" do
    create_email(account_id: 1)
    create_email(account_id: 2)
    create_email(account_id: 3)
    clear_enqueued_jobs
    State.where(tenant_key: %w[1 2]).update_all(priority: "backfill", updated_at: 10.minutes.ago)
    State.where(tenant_key: "3").update_all(updated_at: 10.minutes.ago)
    disable_tenant("2")

    Truffler::Jobs::ResumeJob.perform_now("Email")

    backfills = enqueued_jobs.select { |job| job[:job] == BackfillJob }
    assert_equal [ [ "Email", { "tenant_key" => "1" } ] ], backfills.map { |job| [ job[:args].first, job[:args].last.except("_aj_ruby2_keywords") ] }
    disable_tenant("3")
    clear_enqueued_jobs
    Truffler::Jobs::ResumeJob.perform_now("Email")
    assert_no_enqueued_jobs only: Truffler::Jobs::LabelFlushJob
  end

  test "the embedding backfill is per tenant, honors index_scope, and skips disabled tenants" do
    one = create_note(account_id: 1)
    two = create_note(account_id: 2)
    create_note(account_id: 1, archived: true)
    clear_enqueued_jobs
    backfill = Truffler::Embeddings::Backfill.new(TenantNote)

    assert_equal [ one.id ], backfill.stale_ids(tenant_key: "1")
    assert_equal [ two.id, one.id ], backfill.stale_ids
    disable_tenant("2")
    assert_empty backfill.stale_ids(tenant_key: "2")
    assert_equal [ one.id ], backfill.stale_ids

    Truffler::Jobs::ResumeJob.perform_now("TenantNote")
    assert_equal [ one.id ], enqueued_jobs.select { |job| job[:job] == EmbedJob }.map { |job| job[:args].last }
  end

  test "the embedding backfill query has no NOT IN over the table" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Truffler::Embeddings::Backfill.new(TenantNote).stale_ids(tenant_key: "1", limit: 10)
    end

    select = queries.grep(/FROM "tenant_notes"/).sole
    assert_no_match(/NOT IN/i, select)
    assert_match(/NOT EXISTS/i, select)
  end

  test "EmbedJob skips a record that is no longer indexable" do
    note = create_note
    note.update_columns(archived: true)

    perform_enqueued_jobs(only: EmbedJob)

    assert_empty @embedder.calls
  end

  test "the spend cap applies per tenant ledger: one capped tenant does not stop another" do
    2.times { create_email(account_id: 1) }
    2.times { create_email(account_id: 2) }
    hide_states
    cap = request_cost(2)
    Spend.ledger(Email, Backfill.ledger_version(Email, "1"), tenant_key: "1").settle(cap, requests: 0)

    result = Backfill.new(Email, spend_cap: cap).run

    assert_equal :spend_cap_reached, result.status
    assert_equal [ 2 ], labeled_accounts
    assert_equal [ [ "1", 0 ], [ "2", 1 ] ], Spend.order(:tenant_key).pluck(:tenant_key, :requests)
    assert_nil Backfill.spend(Email)
    assert_equal 1, Backfill.spend(Email, tenant_key: "2").requests
  end

  test "a tenant backfill stops at that tenant's cap and reset_spend! clears only that tenant" do
    2.times { create_email(account_id: 1) }
    hide_states
    cap = request_cost(2)
    Spend.ledger(Email, Backfill.ledger_version(Email, "1"), tenant_key: "1").settle(cap, requests: 0)

    assert_equal :spend_cap_reached, Backfill.new(Email, tenant_key: "1", spend_cap: cap).run.status
    Backfill.reset_spend!(Email, tenant_key: "1")
    assert_equal :complete, Backfill.new(Email, tenant_key: "1", spend_cap: cap).run.status
  end

  test "0.1.6: a worker started before db:migrate moves to tenant ledgers within a minute of tenant_key appearing, without a restart" do
    connection = Spend.connection
    connection.create_table(:legacy_backfill_spends, force: true) do |t|
      t.string :record_type, null: false
      t.string :vocabulary_version, null: false
      t.float :spent_usd, null: false, default: 0.0
      t.integer :requests, null: false, default: 0
      t.timestamps
    end
    connection.add_index :legacy_backfill_spends, [ :record_type, :vocabulary_version ], unique: true, name: "index_legacy_spends_app"
    Spend.table_name = "legacy_backfill_spends"
    Spend.instance_variable_set(:@tenant_key_checked_at, nil)
    create_email(account_id: 1)
    hide_states
    Backfill.new(Email, tenant_key: "1").run
    assert_not Spend.tenant_ledgers?

    connection.add_column :legacy_backfill_spends, :tenant_key, :string
    connection.remove_index :legacy_backfill_spends, name: "index_legacy_spends_app"
    connection.add_index :legacy_backfill_spends, [ :record_type, :tenant_key, :vocabulary_version ], unique: true,
      name: "index_legacy_spends_tenant"
    assert_not Spend.tenant_ledgers?

    travel 61.seconds do
      create_email(account_id: 1)
      hide_states
      Backfill.new(Email, tenant_key: "1").run

      assert Spend.tenant_ledgers?
      assert_equal [ [ nil, 1 ], [ "1", 1 ] ], Spend.order(:id).pluck(:tenant_key, :requests)
    end
  ensure
    Spend.table_name = "truffler_backfill_spends"
    Spend.instance_variable_set(:@tenant_key_checked_at, nil)
    Spend.connection.drop_table(:legacy_backfill_spends, if_exists: true)
  end

  test "backfill_spend_cap_scope :app keeps one app-wide ledger for a scoped model" do
    Truffler.config.backfill_spend_cap_scope = :app
    create_email(account_id: 1)
    create_email(account_id: 2)
    hide_states

    Backfill.new(Email).run

    assert_equal [ [ nil, 2 ] ], Spend.pluck(:tenant_key, :requests)
    assert_equal 2, Backfill.spend(Email).requests
  end

  test "unscoped models keep the app-wide ledger" do
    Truffler.config.client = Truffler::Clients::Fake.new
    widget = Class.new(ActiveRecord::Base) do
      self.table_name = "tenant_notes"
      def self.name = "UnscopedTenantNote"
      include Truffler::Model
      truffler do
        reads :title
        label :spam, :noul, question: "Is this spam?"
      end
    end
    widget.create!(account_id: 1, title: "A")
    hide_states

    Backfill.new(widget).run

    assert_equal [ [ nil, "UnscopedTenantNote" ] ], Spend.pluck(:tenant_key, :record_type)
  end

  test "rake truffler:backfill TENANT= backfills one tenant" do
    create_email(account_id: 1)
    create_email(account_id: 2)
    hide_states
    Rake.application = Rake::Application.new
    load File.expand_path("../../lib/tasks/truffler.rake", __dir__)

    output, = with_env("TENANT" => "2") { capture_io { Rake.application["truffler:backfill"].invoke("Email") } }

    assert_match(/Email \(tenant 2\): complete, 1 labeled/, output)
    assert_equal [ 2 ], labeled_accounts
  ensure
    Rake.application = Rake::Application.new
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  test "0.1.5: the labeler keeps a disabled tenant's state rows, back at pending backfill" do
    create_email(account_id: 2)
    disable_tenant("2")
    states = Truffler::Labeling::Queue.new(Email).claim("2", priority: :live, limit: 10)

    Truffler::Labeling::Labeler.new(Email).label(states, priority: :live)

    assert_empty @fake.calls
    assert_equal [ %w[pending backfill] ], State.where(tenant_key: "2").pluck(:status, :priority)
  end

  test "0.1.5: status counts only what the backfill may touch (Bugbot)" do
    create_note(account_id: 1)
    create_note(account_id: 1, archived: true)
    create_note(account_id: 2)
    hide_states
    disable_tenant("2")

    Backfill.new(TenantNote).run
    status = Backfill.status(TenantNote)

    assert_equal 1, status[:total]
    assert_equal 0, status[:missing]
    assert_equal 1, status[:current]
    assert_equal 1, Backfill.status(TenantNote, tenant_key: "1")[:total]
  end

  test "0.1.6: status and backfill work with an index_scope that orders (SELECT DISTINCT on Postgres)" do
    ordered = Class.new(ActiveRecord::Base) do
      self.table_name = "tenant_notes"
      def self.name = "OrderedTenantNote"
      include Truffler::Model
      truffler do
        tenant :account_id
        reads :title
        label :spam, :noul, question: "Is this note spam?"
        index_scope ->(relation) { relation.where(archived: false).order(:title) }
      end
    end
    Truffler.config.client = Truffler::Clients::Fake.new.answer(:spam, 0.1)
    ordered.create!(account_id: 1, title: "B")
    ordered.create!(account_id: 2, title: "A")
    hide_states
    disable_tenant("2")

    Backfill.new(ordered).run
    status = Backfill.status(ordered)

    assert_equal 1, status[:total]
    assert_equal 1, status[:current]
  end

  test "0.1.5: status ignores state rows left by records that moved out of index_scope (Bugbot)" do
    kept = create_note(account_id: 1)
    archived = create_note(account_id: 1)
    perform_enqueued_jobs(only: Truffler::Jobs::LabelFlushJob)
    archived.update_columns(archived: true)

    status = Backfill.status(TenantNote)

    assert_equal 1, status[:total]
    assert_equal 1, status[:labeled]
    assert_equal [ kept.id, archived.id ].sort, State.where(record_type: "TenantNote").pluck(:record_id).sort
  end
end
