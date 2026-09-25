require "test_helper"

begin
  require "sqlite_vec"
rescue LoadError
  nil
end

class NeighborStoreTest < Truffler::TestCase
  Neighbor = Truffler::Embeddings::NeighborStore

  def self.load_sqlite_vec
    path = ENV["TRUFFLER_SQLITE_VEC_PATH"].presence || (SqliteVec.loadable_path if defined?(SqliteVec))
    return "sqlite-vec not available (add the sqlite-vec gem or set TRUFFLER_SQLITE_VEC_PATH)" unless path

    raw = ActiveRecord::Base.connection.raw_connection
    raw.enable_load_extension(true)
    raw.load_extension(path)
    raw.enable_load_extension(false)
    nil
  rescue StandardError => error
    "sqlite-vec failed to load (#{error.class})"
  end

  SKIP_REASON = load_sqlite_vec

  def require_sqlite_vec
    skip SKIP_REASON if SKIP_REASON
  end

  def note_with_vector(vector, account_id: 1)
    note = EmbeddedNote.create!(account_id: account_id, title: "Note")
    Neighbor.new.write(EmbeddedNote, note, vector, fingerprint: "fp")
    note
  end

  test "sqlite SQL reads float32 blobs with vec_distance_cosine" do
    sql = Neighbor.distance_sql(:sqlite, ActiveRecord::Base.connection, "e.embedding", [ 1.0 ])

    assert_equal "vec_distance_cosine(e.embedding, X'0000803f')", sql
  end

  test "postgres SQL uses pgvector's cosine operator on a vector literal" do
    sql = Neighbor.distance_sql(:postgres, ActiveRecord::Base.connection, "e.embedding", [ 1, 0.5 ])

    assert_equal "(e.embedding <=> '[1.0,0.5]'::vector)", sql
  end

  test "without pgvector or sqlite-vec the store explains what it needs" do
    error = assert_raises(Truffler::Error) { Neighbor.distance_sql(nil, ActiveRecord::Base.connection, "e.embedding", [ 1.0 ]) }

    assert_match(/sqlite-vec/, error.message)
  end

  test "auto picks the neighbor store when sqlite-vec loads" do
    require_sqlite_vec

    assert Neighbor.available?(ActiveRecord::Base.connection)
    assert_instance_of Neighbor, Truffler::Embeddings::VectorStore.for(EmbeddedNote)
  end

  test "nearest orders by cosine within the tenant, matching the ruby store" do
    require_sqlite_vec
    close = note_with_vector([ 1.0, 0.1, 0.0 ])
    far = note_with_vector([ 0.0, 0.0, 1.0 ])
    middle = note_with_vector([ 0.7, 0.7, 0.0 ])
    note_with_vector([ 1.0, 0.0, 0.0 ], account_id: 2)

    pairs = Neighbor.new.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ], k: 3)
    expected = Truffler::Embeddings::RubyStore.new.nearest(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ], k: 3)

    assert_equal [ close.id, middle.id, far.id ], pairs.map(&:first)
    pairs.zip(expected).each { |(_, got), (_, want)| assert_in_delta want, got, 0.0001 }
  end

  test "similarity_sql scores every row inline in the caller's query" do
    require_sqlite_vec
    close = note_with_vector([ 1.0, 0.1, 0.0 ])
    far = note_with_vector([ 0.0, 1.0, 0.0 ])
    bare = EmbeddedNote.create!(account_id: 1, title: "No vector yet")
    note_with_vector([ 1.0, 0.0, 0.0 ], account_id: 2)
    store = Neighbor.new

    sql = store.similarity_sql(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0, 0.0 ])
    rows = EmbeddedNote.where(account_id: 1).order(Arel.sql("#{sql} DESC"), :id).pluck(:id, Arel.sql(sql))

    assert store.inline_sql?(EmbeddedNote)
    assert_equal [ close.id, far.id, bare.id ], rows.map(&:first)
    assert_in_delta 0.995, rows[0].last, 0.001
    assert_in_delta 0.0, rows[1].last, 0.0001
    assert_equal 0.0, rows[2].last
  end

  test "similarity_sql never reads another tenant's vector for the same record id" do
    require_sqlite_vec
    note = note_with_vector([ 1.0, 0.0 ])
    Truffler::Records::Embedding.where(record_id: note.id).update_all(tenant_key: "2")

    sql = Neighbor.new.similarity_sql(EmbeddedNote, tenant_key: "1", vector: [ 1.0, 0.0 ])

    assert_equal 0.0, EmbeddedNote.where(id: note.id).pick(Arel.sql(sql))
  end
end
