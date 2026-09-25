require "test_helper"

class RubyStoreTest < Truffler::TestCase
  Embedding = Truffler::Records::Embedding

  setup do
    Truffler.config.vector_store = :ruby
    @store = Truffler::Embeddings::VectorStore.for(EmbeddedNote)
  end

  def note_with_vector(vector, account_id: 1)
    note = EmbeddedNote.create!(account_id: account_id, title: "Note")
    @store.write(EmbeddedNote, note, vector, fingerprint: "fp")
    note
  end

  test "config picks the ruby store" do
    assert_instance_of Truffler::Embeddings::RubyStore, @store
    assert_not @store.inline_sql?(EmbeddedNote)
  end

  test "stores a packed float blob with its width and fingerprint" do
    note = note_with_vector([ 0.25, -0.5, 1.0 ])

    row = Embedding.find_by!(record_id: note.id)
    assert_equal [ 0.25, -0.5, 1.0 ], row.vector
    assert_equal [ 3, "fp", "1" ], [ row.dimensions, row.fingerprint, row.tenant_key ]
  end

  test "nearest returns the most similar record first" do
    close = note_with_vector([ 1.0, 0.1, 0.0 ])
    far = note_with_vector([ 0.0, 0.0, 1.0 ])
    middle = note_with_vector([ 0.7, 0.7, 0.0 ])

    pairs = @store.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ], k: 3)

    assert_equal [ close.id, middle.id, far.id ], pairs.map(&:first)
    assert_in_delta 0.995, pairs.first.last, 0.001
    assert_equal [ close.id ], @store.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ], k: 1).map(&:first)
  end

  test "never returns another tenant's rows" do
    mine = note_with_vector([ 0.1, 1.0, 0.0 ], account_id: 1)
    note_with_vector([ 1.0, 0.0, 0.0 ], account_id: 2)

    assert_equal [ mine.id ], @store.nearest(EmbeddedNote, tenant_key: 1, vector: [ 1.0, 0.0, 0.0 ]).map(&:first)
  end

  test "vector search on a scoped model needs a tenant" do
    assert_raises(Truffler::MissingScope) { @store.nearest(EmbeddedNote, tenant_key: nil, vector: [ 1.0 ]) }
  end

  test "skips vectors of another width, such as after a model change" do
    note_with_vector([ 1.0, 0.0 ])
    same = note_with_vector([ 1.0, 0.0, 0.0 ])

    assert_equal [ same.id ], @store.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ]).map(&:first)
  end

  test "rows holding only a label vector are not text neighbors" do
    note = EmbeddedNote.create!(account_id: 1, title: "Labels only")
    Truffler::Embeddings::LabelVector.new(EmbeddedNote).write([ note.id ], tenant_key: "1")

    assert_empty @store.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0 ])
  end

  test "similarity_sql falls back to a top-K CASE that search can order by" do
    close = note_with_vector([ 1.0, 0.1, 0.0 ])
    far = note_with_vector([ 0.0, 1.0, 0.0 ])
    outside = note_with_vector([ 1.0, 0.0, 0.0 ], account_id: 2)

    sql = @store.similarity_sql(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ], k: 1)
    rows = EmbeddedNote.where(account_id: 1).order(Arel.sql("#{sql} DESC"), :id).pluck(:id, Arel.sql(sql))

    assert_equal [ close.id, far.id ], rows.map(&:first)
    assert_in_delta 0.995, rows.first.last, 0.001
    assert_equal 0.0, rows.last.last
    assert_not_includes rows.map(&:first), outside.id
  end

  test "similarity_sql with no neighbors is a constant zero" do
    assert_equal "0.0", @store.similarity_sql(EmbeddedNote, tenant_key: "1", vector: [ 1.0 ]).to_s
  end

  test "unknown adapters and models without embeddings" do
    assert_nil Truffler::Embeddings::VectorStore.for(Email)

    Truffler.config.vector_store = :faiss
    assert_raises(Truffler::Error) { Truffler::Embeddings::VectorStore.for(EmbeddedNote) }
  end
end
