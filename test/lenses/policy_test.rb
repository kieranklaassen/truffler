require "test_helper"

class PolicyTest < Truffler::TestCase
  include Truffler::Test::LensHelpers

  Scope = Truffler::Lenses::Scope
  Activator = Truffler::Lenses::Activator

  test "with creators :developers a non-admin activation raises NotAuthorized and an admin's succeeds" do
    draft = dutch_draft

    assert_raises(Truffler::NotAuthorized) { Activator.activate(draft, by: member) }
    assert_equal 0, Truffler::Lenses::Lens.count

    assert Activator.activate(draft, by: admin).active?
  end

  test "without an authorize_lens hook every change is refused" do
    Truffler.config.lenses.authorize_lens = nil

    error = assert_raises(Truffler::NotAuthorized) { Activator.activate(dutch_draft, by: admin) }
    assert_match(/authorize_lens/, error.message)
  end

  test "the host hook receives the user and the scope" do
    seen = []
    Truffler.config.lenses.authorize_lens = ->(user, scope) { seen << [ user, scope ] }

    Activator.activate(dutch_draft, by: admin)

    assert_includes seen, [ admin, Scope.tenant("1") ]
  end

  test "with creators :tenant_users, users may create tenant lenses for their own tenant but not app lenses" do
    Truffler.config.lenses.creators = :tenant_users
    Truffler.config.lenses.authorize_lens = ->(user, scope) { scope.tenant_key == user.account_id.to_s }

    assert_raises(Truffler::NotAuthorized) { Activator.activate(dutch_draft(scope: Scope.app), by: member) }
    assert_raises(Truffler::NotAuthorized) { Activator.activate(dutch_draft(scope: Scope.tenant("2")), by: member) }
    assert Activator.activate(dutch_draft(scope: Scope.tenant("1")), by: member).active?
  end

  test "with creators :each_user, a user's lens is invisible to another user's searches and encodings" do
    Truffler.config.lenses.creators = :each_user
    Truffler.config.lenses.authorize_lens = ->(user, scope) { scope.tenant_key == user.account_id.to_s }
    alice = member(2)
    bob = member(3)

    lens = dutch_lens(scope: Scope.user("1", alice.id), by: alice)

    assert_equal [ "lens:#{lens.id}:language" ], Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1", user_key: alice.id).keys
    assert_empty Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1", user_key: bob.id)
    assert_empty Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "1")
    assert_nil Truffler::Lenses.lens_fingerprints(FeedMessage, tenant_key: "1", user_key: bob.id)
    assert_empty Truffler::Lenses.visible_questions(FeedMessage, tenant_key: "2", user_key: alice.id)
  end

  test "with creators :each_user, only personal lenses are allowed and only their owner may change them" do
    Truffler.config.lenses.creators = :each_user
    Truffler.config.lenses.authorize_lens = ->(_user, _scope) { true }
    alice = member(2)
    bob = member(3)

    assert_raises(Truffler::NotAuthorized) { Activator.activate(dutch_draft(scope: Scope.tenant("1")), by: alice) }
    assert_raises(Truffler::NotAuthorized) { Activator.activate(dutch_draft(scope: Scope.user("1", alice.id)), by: bob) }

    lens = dutch_lens(scope: Scope.user("1", alice.id), by: alice)
    assert_raises(Truffler::NotAuthorized) { lens.regenerate(by: bob) }
    assert_raises(Truffler::NotAuthorized) { lens.restore!(1, by: bob) }
    assert_equal 1, lens.versions.count
  end

  test "creators must be a known mode" do
    assert_raises(ArgumentError) { Truffler.config.lenses.creators = :everyone }
  end

  test "stored lenses and versions carry keyed digests of their authors, never raw user keys" do
    lens = dutch_lens

    assert_equal Truffler::Lenses.digest("1"), lens.creator_digest
    assert_equal Truffler::Lenses.digest("1"), lens.versions.sole.created_by_digest
    assert_not_equal "1", lens.creator_digest
  end
end
