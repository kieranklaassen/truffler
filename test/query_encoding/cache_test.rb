require "test_helper"

class QueryEncodingCacheTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Cache = Truffler::QueryEncoding::Cache
  Prefetch = Truffler::QueryEncoding::Prefetch
  Query = Truffler::Search::Query

  def key_for(model, query, tenant: "1")
    Cache.new.key(model, Query.new(query), tenant_key: tenant)
  end

  def prefetch(model, query, tenant: "1", user: "user-1")
    Prefetch.new.call(model, Query.new(query), cache_key: key_for(model, query, tenant: tenant), tenant_key: tenant, user_key: user)
  end

  test "the default encoding_prefetch hook is the query encoder's prefetch" do
    assert_instance_of Prefetch, Truffler.config.encoding_prefetch
  end

  test "the same query with different casing and spacing shares a key, and a vocabulary change misses" do
    key = key_for(InboxEmail, "Needs  ACTION ")

    assert_match(%r{\Atruffler/enc/\h{64}\z}, key)
    assert_equal key, key_for(InboxEmail, "needs action")
    Truffler.config.model = "jev-next"
    assert_not_equal key, key_for(InboxEmail, "needs action")
  end

  test "per-tenant choice options give each tenant its own key; otherwise tenants share one" do
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "emails"
      def self.name = "FolderEmail"
      include Truffler::Model

      truffler do
        tenant :account_id
        reads :subject
        label :folder, :choice, question: "Which folder?", options: ->(tenant) { tenant == "1" ? %w[a b] : %w[c d] }
      end
    end

    assert_not_equal key_for(model, "work", tenant: "1"), key_for(model, "work", tenant: "2")
    assert_equal key_for(InboxEmail, "work", tenant: "1"), key_for(InboxEmail, "work", tenant: "2")
  end

  test "a duplicate prefetch within the in-flight window enqueues one job and reports in flight both times" do
    assert prefetch(InboxEmail, "invoice")
    assert prefetch(InboxEmail, "Invoice ")

    assert_enqueued_jobs 1, only: Truffler::Jobs::EncodeQueryJob
    assert Cache.new.in_flight?(key_for(InboxEmail, "invoice"))
  end

  test "two keystrokes of a new query enqueue one encode job" do
    search(InboxEmail, "invoice")
    search(InboxEmail, "invoice")

    assert_enqueued_jobs 1, only: Truffler::Jobs::EncodeQueryJob
  end

  test "the job carries only the cache key, and cached values never hold the query text" do
    Truffler.config.client = Truffler::Clients::Fake.new { |tag| { "intent" => "filter", "token" => "keyword" }[tag] }
    prefetch(InboxEmail, "secret merger plans")

    assert_equal [ key_for(InboxEmail, "secret merger plans") ], enqueued_jobs.sole[:args]
    perform_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)
    store = Truffler.config.cache_store
    key = key_for(InboxEmail, "secret merger plans")
    assert_not_includes store.read(key).to_json, "merger"
    assert_nil store.read(Cache.new.payload_key(key))
    assert_not Cache.new.in_flight?(key)
  end

  test "an encrypted model's pending query is encrypted in the cache" do
    prefetch(SecretNote, "my diagnosis")

    payload = Truffler.config.cache_store.read(Cache.new.payload_key(key_for(SecretNote, "my diagnosis")))
    assert payload["encrypted"]
    assert_not_includes payload.to_json, "diagnosis"
    assert_equal "my diagnosis", Cache.new.read_payload(key_for(SecretNote, "my diagnosis"))[:query].normalized
  end

  test "an encrypted model without ActiveRecord encryption configured is not prefetched" do
    Truffler::Misses.stub(:encryption_configured?, false) do
      assert_not prefetch(SecretNote, "my diagnosis")
    end
    assert_no_enqueued_jobs(only: Truffler::Jobs::EncodeQueryJob)
  end

  test "nothing is prefetched when the encoding is cached and the query vector is not the gem's to compute" do
    cache_encoding!(ColumnDocument, "spam", boosts: { spam: 1.0 })

    assert_not prefetch(ColumnDocument, "spam")
    assert prefetch(EmbeddedNote, "spam")
  end
end
