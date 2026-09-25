module Truffler
  # State scoped to one unit of work: a keystroke search, a query encoding,
  # a labeler batch, a Smart run step. Inside `scope`, a per-tenant choice
  # `options:` callable is resolved once per (label, tenant) instead of at
  # every vocabulary, fingerprint, and wording read. Nested scopes share the
  # outermost one, which clears everything when it ends, so nothing carries
  # over to the next search or job. Outside a scope nothing is memoized.
  module Current
    KEY = :truffler_current_options

    def self.scope
      return yield if ActiveSupport::IsolatedExecutionState.key?(KEY)

      ActiveSupport::IsolatedExecutionState[KEY] = {}
      begin
        yield
      ensure
        ActiveSupport::IsolatedExecutionState.delete(KEY)
      end
    end

    def self.options(label, tenant_key)
      memo = ActiveSupport::IsolatedExecutionState[KEY]
      return yield unless memo

      key = [ label, tenant_key&.to_s ]
      memo.fetch(key) { memo[key] = yield }
    end
  end
end
