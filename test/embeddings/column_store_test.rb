require "test_helper"

class ColumnStoreTest < Truffler::TestCase
  setup do
    @embedder = Truffler::Embeddings::FakeEmbedder.new
    Truffler.config.embedder = @embedder
    @store = Truffler::Embeddings::VectorStore.for(ColumnDocument)
  end

  def document(vector, account_id: 1)
    ColumnDocument.create!(account_id: account_id, title: "Doc", embedding: vector && JSON.generate(vector))
  end

  test "a declared column selects the column store" do
    assert_instance_of Truffler::Embeddings::ColumnStore, @store
    assert_equal "embedding", @store.column
  end

  test "returns neighbors from the host column without gem embedding rows or embedder calls" do
    close = document([ 1.0, 0.1, 0.0 ])
    far = document([ 0.0, 1.0, 0.0 ])
    document(nil)
    document([ 1.0, 0.0, 0.0 ], account_id: 2)

    pairs = @store.nearest(ColumnDocument, tenant_key: 1, vector: [ 1.0, 0.0, 0.0 ], k: 5)

    assert_equal [ close.id, far.id ], pairs.map(&:first)
    assert_in_delta 0.995, pairs.first.last, 0.001
    assert_equal 0, Truffler::Records::Embedding.where.not(embedding: nil).count
    assert_empty @embedder.calls
    assert_no_enqueued_jobs(only: Truffler::Jobs::EmbedJob) { document([ 1.0, 0.0, 0.0 ]) }
  end

  test "needs a tenant and refuses to write the host column" do
    assert_raises(Truffler::MissingScope) { @store.nearest(ColumnDocument, tenant_key: nil, vector: [ 1.0 ]) }
    assert_raises(Truffler::Error) { @store.write(ColumnDocument, document([ 1.0 ]), [ 1.0 ], fingerprint: "fp") }
  end

  test "similarity_sql orders the host table by the column's similarity" do
    close = document([ 1.0, 0.1, 0.0 ])
    far = document([ 0.0, 1.0, 0.0 ])

    sql = @store.similarity_sql(ColumnDocument, tenant_key: 1, vector: [ 1.0, 0.0, 0.0 ])
    rows = ColumnDocument.where(account_id: 1).order(Arel.sql("#{sql} DESC")).pluck(:id, Arel.sql(sql))

    assert_equal [ close.id, far.id ], rows.map(&:first)
    assert_in_delta 0.995, rows.first.last, 0.001
  end
end
