require "test_helper"

class EmbedJobTest < Truffler::TestCase
  Embedding = Truffler::Records::Embedding
  State = Truffler::Records::RecordState
  EmbedJob = Truffler::Jobs::EmbedJob
  BODY = "Wire the escrow funds to account 4471 before Friday".freeze

  setup do
    @embedder = Truffler::Embeddings::FakeEmbedder.new
    Truffler.config.embedder = @embedder
    Truffler.config.vector_store = :ruby
    Truffler.config.client = Truffler::Clients::Fake.new.answer(:spam, 0.1)
  end

  def create_note(**attributes)
    EmbeddedNote.create!(account_id: 1, title: "Escrow", body: BODY, **attributes)
  end

  test "creating a record enqueues one EmbedJob carrying only the type and id" do
    note = create_note

    jobs = enqueued_jobs.select { |job| job["job_class"] == EmbedJob.name }
    assert_equal [ [ "EmbeddedNote", note.id ] ], jobs.map { |job| job["arguments"] }
    assert_not_includes jobs.to_s, "escrow"
  end

  test "models without embeddings enqueue no EmbedJob" do
    assert_no_enqueued_jobs(only: EmbedJob) { Email.create!(account_id: 1, subject: "Hi") }
  end

  test "performing it stores one 256-float vector with no source text in the row" do
    note = create_note

    perform_enqueued_jobs(only: EmbedJob)

    row = Embedding.find_by!(record_type: "EmbeddedNote", record_id: note.id)
    assert_equal 256, row.vector.size
    assert_equal 256, row.dimensions
    assert_equal Truffler::Embeddings.fingerprint(EmbeddedNote.truffler_definition), row.fingerprint
    assert_equal [ [ "title: Escrow\nbody: #{BODY}" ] ], @embedder.calls.map { |call| call[:texts] }
    assert_equal [ "text-embedding-3-small", 256 ], @embedder.calls.first.values_at(:model, :dimensions)
    row.attributes.each_value { |value| assert_not_includes value.to_s, "escrow" unless value.is_a?(Numeric) }
    state = State.find_by!(record_id: note.id)
    assert_equal row.fingerprint, state.embedding_fingerprint
    assert_not_nil state.embedded_at
  end

  test "the stored vector is searchable by the tenant" do
    note = create_note
    create_note(title: "Picnic", body: "Sandwiches in the park")
    perform_enqueued_jobs(only: EmbedJob)

    query = @embedder.vector_for("escrow funds wire", 256)
    nearest = Truffler::Embeddings::VectorStore.for(EmbeddedNote).nearest(EmbeddedNote, tenant_key: "1", vector: query, k: 1)

    assert_equal note.id, nearest.sole.first
  end

  test "editing a read field re-embeds, and other fields enqueue nothing" do
    note = create_note
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: EmbedJob) { note.update!(color: "red") }
    assert_enqueued_with(job: EmbedJob, args: [ "EmbeddedNote", note.id ]) { note.update!(body: "New body") }
  end

  test "an embedder error leaves embedded_at nil, retries, and leaves labels alone" do
    note = create_note
    perform_enqueued_jobs(except: EmbedJob)
    labels = Truffler::Records::Label.pluck(:label_key, :value)
    @embedder.fail_with(Truffler::Test::HttpError.new(503, "down"))

    perform_enqueued_jobs(only: EmbedJob)

    assert_nil State.find_by!(record_id: note.id).embedded_at
    assert_nil Embedding.find_by(record_id: note.id)&.embedding
    assert_equal labels, Truffler::Records::Label.pluck(:label_key, :value)
    assert_equal [ "labeled" ], State.pluck(:status)
    assert_enqueued_jobs 1, only: EmbedJob

    @embedder.recover!
    perform_enqueued_jobs(only: EmbedJob)

    assert_not_nil State.find_by!(record_id: note.id).embedded_at
  end

  test "changing the embedding model marks the fingerprint stale, and backfill re-embeds" do
    note = create_note
    perform_enqueued_jobs(only: EmbedJob)
    backfill = Truffler::Embeddings::Backfill.new(EmbeddedNote)
    assert_empty backfill.stale_ids

    definition = EmbeddedNote.truffler_definition
    original = definition.embeddings
    definition.embeddings = original.merge(model: "text-embedding-3-large")

    assert_equal [ note.id ], backfill.stale_ids
    assert_equal 1, backfill.enqueue
    perform_enqueued_jobs(only: EmbedJob)

    assert_equal "text-embedding-3-large", @embedder.calls.last[:model]
    assert_empty backfill.stale_ids
    assert_equal Truffler::Embeddings.fingerprint(definition), Embedding.find_by!(record_id: note.id).fingerprint
  ensure
    definition.embeddings = original if original
  end

  test "backfill picks up records that were never embedded, newest first" do
    older = create_note
    newer = create_note
    clear_enqueued_jobs

    assert_equal [ newer.id ], Truffler::Embeddings::Backfill.new(EmbeddedNote).stale_ids(limit: 1)
    assert_equal 2, Truffler::Embeddings::Backfill.new(EmbeddedNote).enqueue
    assert_enqueued_with(job: EmbedJob, args: [ "EmbeddedNote", older.id ])
  end

  test "backfill enqueues in cursor batches and stops at the limit" do
    notes = Array.new(5) { create_note }
    clear_enqueued_jobs
    batches = []
    subscriber = ActiveSupport::Notifications.subscribe("enqueue_all.active_job") { |*, payload| batches << payload[:jobs].size }

    assert_equal 4, Truffler::Embeddings::Backfill.new(EmbeddedNote).enqueue(limit: 4, batch_size: 2)
    assert_equal [ 2, 2 ], batches
    assert_equal notes.last(4).map(&:id).sort, enqueued_jobs.map { |job| job[:args].last }.sort

    clear_enqueued_jobs
    batches.clear
    assert_equal 5, Truffler::Embeddings::Backfill.new(EmbeddedNote).enqueue(batch_size: 2)
    assert_equal [ 2, 2, 1 ], batches
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "the resume sweep enqueues a bounded embeddings backfill once per interval" do
    3.times { create_note }
    clear_enqueued_jobs

    previous = Truffler::Jobs::ResumeJob.embedding_sweep_limit
    Truffler::Jobs::ResumeJob.embedding_sweep_limit = 2

    Truffler::Jobs::ResumeJob.perform_now("EmbeddedNote")
    assert_enqueued_jobs 2, only: EmbedJob

    clear_enqueued_jobs
    Truffler::Jobs::ResumeJob.perform_now("EmbeddedNote")
    assert_no_enqueued_jobs only: EmbedJob
  ensure
    Truffler::Jobs::ResumeJob.embedding_sweep_limit = previous
  end

  test "the resume sweep leaves host-maintained vector columns alone" do
    ColumnDocument.create!(account_id: 1, title: "Escrow")
    clear_enqueued_jobs

    Truffler::Jobs::ResumeJob.perform_now("ColumnDocument")

    assert_no_enqueued_jobs only: EmbedJob
  end

  test "a deleted record drops its embedding row" do
    note = create_note
    perform_enqueued_jobs(only: EmbedJob)
    EmbeddedNote.where(id: note.id).delete_all

    EmbedJob.perform_now("EmbeddedNote", note.id)

    assert_equal 0, Embedding.count
  end
end
