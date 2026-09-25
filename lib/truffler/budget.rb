module Truffler
  # One account-wide Jev request budget shared by every gem call. The gem's
  # share is the account limit minus headroom for the app's other Jev calls,
  # counted per second in the cache store so bursts spread across the minute.
  # Each priority may fill the second only up to its ceiling, so lower
  # priorities give way first: live labeling, then query encoding, then
  # rerank, then backfill.
  #
  # Outcomes: :granted takes a slot; :demoted means a tenant is over its live
  # cap and its records should wait at backfill priority (no slot is taken);
  # :denied means skip, pause, or reschedule, with `retry_after` seconds until
  # the denying window rolls over. Only live callers wait, up to max_wait. A
  # cache that cannot count (the null store) never blocks.
  class Budget
    PRIORITIES = %i[live encode rerank backfill].freeze

    Decision = Data.define(:outcome, :priority, :reason, :retry_after) do
      def initialize(outcome:, priority:, reason:, retry_after: nil)
        super
      end

      def granted? = outcome == :granted
      def demoted? = outcome == :demoted
      def denied? = outcome == :denied
    end

    attr_reader :config

    def initialize(config: Truffler.config, cache: config.cache_store,
      clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) }, sleeper: ->(seconds) { sleep(seconds) })
      @config = config
      @cache = cache
      @clock = clock
      @sleeper = sleeper
    end

    def acquire(priority:, user_key: nil, tenant_key: nil, records: 1)
      priority = priority.to_sym
      raise ArgumentError, "priority must be one of #{PRIORITIES.join(', ')}" unless PRIORITIES.include?(priority)

      taken = []
      if priority == :live && tenant_key
        return Decision.new(:demoted, :backfill, :tenant_cap) unless take(tenant_counter(tenant_key), records, config.tenant_live_cap, taken)
      end
      if (cap = config.user_caps[priority]) && user_key
        return deny(priority, :user_cap, taken, until_next_minute) unless take(user_counter(priority, user_key), 1, cap, taken)
      end
      return deny(priority, :exhausted, taken, until_next_second) unless take_second(priority)

      Decision.new(:granted, priority, nil)
    end

    # Counts one unit against the per-user cap for `priority` without taking
    # a request slot, for callers that gate work but make no Jev call
    # themselves (the Smart dispatcher; each rerank chunk acquires its own).
    def admit(priority:, user_key:)
      priority = priority.to_sym
      raise ArgumentError, "priority must be one of #{PRIORITIES.join(', ')}" unless PRIORITIES.include?(priority)

      cap = config.user_caps[priority]
      return Decision.new(:granted, priority, nil) unless cap && user_key
      return deny(priority, :user_cap, [], until_next_minute) unless take(user_counter(priority, user_key), 1, cap)

      Decision.new(:granted, priority, nil)
    end

    def gem_per_minute
      (config.requests_per_minute * (1 - config.headroom)).floor
    end

    def ceiling(priority)
      [ gem_per_minute / 60.0 * config.priority_ceilings.fetch(priority), 1 ].max
    end

    private

    def take_second(priority)
      deadline = @clock.call + (priority == :live ? config.max_wait : 0)
      loop do
        now = @clock.call
        second = now.floor
        return true if take("second/#{second}", 1, ceiling(priority))

        wait = second + 1 - now
        return false if now + wait > deadline

        @sleeper.call(wait)
      end
    end

    def take(counter, amount, limit, taken = nil)
      key = "truffler/budget/#{counter}"
      count = @cache.increment(key, amount, expires_in: 2.minutes)
      return true if count.nil?

      if count <= limit
        taken&.push([ key, amount ])
        true
      else
        @cache.decrement(key, amount, expires_in: 2.minutes)
        false
      end
    end

    def deny(priority, reason, taken, retry_after)
      taken.each { |key, amount| @cache.decrement(key, amount, expires_in: 2.minutes) }
      Instrumentation.instrument(:budget_denied, priority: priority)
      Decision.new(:denied, priority, reason, retry_after)
    end

    def until_next_second
      now = @clock.call
      now.floor + 1 - now
    end

    def until_next_minute
      now = @clock.call
      (minute + 1) * 60 - now
    end

    def tenant_counter(tenant_key)
      "tenant/#{tenant_key}/#{minute}"
    end

    def user_counter(priority, user_key)
      "user/#{priority}/#{user_key}/#{minute}"
    end

    def minute
      (@clock.call / 60).floor
    end
  end
end
