require "securerandom"

module Truffler
  module SmartSearch
    # One Smart search, read through its `Store` entries. Everything the host
    # renders comes from here (Host UI Contract Map, R22-R24, R26):
    #
    # - `reserved?` / `reserved_slots`: the Smart section holds its space from
    #   the moment the action fires, sized to the candidate snapshot.
    # - `buckets`: `{strong:, possible:, unlikely:}` of `{id:, score:}`,
    #   append-only in chunk arrival order, sorted only within a chunk, so
    #   nothing moves once shown.
    # - `promoted_ids`: ids shown in Strong or Possible; the keystroke list
    #   keeps them in place and marks them.
    # - `pending?(bucket)`, `collapsed_by_default`, `no_strong_matches?`.
    # - `status`: :pending, :running, :complete, :paused (over budget),
    #   :cancelled (edited, chip changed, or superseded), :expired (evicted).
    # - sections: host sections beside Smart results, such as the provider
    #   backup (`provider_section`), each written through `update_section`.
    class Run
      STATUSES = %i[pending running complete paused cancelled expired].freeze
      RESOLVED_CHUNKS = %w[done failed].freeze
      ABSENT = { "status" => :absent }.freeze

      attr_reader :id, :store

      def self.create(model, query:, tenant_key:, user_key:, surface:, suppressed:, pool_ids:, local_ids:, local_weak:,
        explicit_action:, store: Store.new)
        run = new(SecureRandom.uuid, store: store)
        core = { "record_type" => model.polymorphic_name, "tenant_key" => tenant_key, "user_key" => user_key,
          "surface" => surface, "suppressed" => suppressed, "pool_ids" => pool_ids, "local_ids" => local_ids,
          "local_weak" => local_weak, "explicit_action" => explicit_action&.to_s, "created_at" => Time.current.iso8601(6) }
        store.write(run.id, nil, core.merge(store.seal(model, query)))
        run
      end

      # The run for `run_id` as `user` in `tenant` sees it: a run that belongs
      # to another searcher or tenant reads as expired (R17).
      def self.find(run_id, user:, tenant:, store: Store.new)
        run = load(run_id, store: store)
        owned = !run.expired? && run.user_key == Search::Keystroke.user_key(user) && run.tenant_key == tenant&.to_s
        owned ? run : new(run_id, store: store, core: {})
      end

      # Loads a run by id with no owner check, for jobs and internal callers
      # that hold only the run id. Never hand its result to a request.
      def self.load(run_id, store: Store.new)
        new(run_id, store: store)
      end

      def initialize(id, store: Store.new, core: nil)
        @id = id.to_s
        @store = store
        @core = core
      end

      def core
        @core ||= store.read(id) || {}
      end

      def expired?
        core.empty?
      end

      def model
        core["record_type"]&.safe_constantize
      end

      def record_type = core["record_type"]
      def tenant_key = core["tenant_key"]
      def user_key = core["user_key"]
      def surface = core["surface"]
      def suppressed = Array(core["suppressed"])
      def local_ids = Array(core["local_ids"])
      def local_weak? = core["local_weak"] == true
      def explicit_action = core["explicit_action"]&.to_sym

      # The ids snapshotted from the caller's scope when the action fired
      # (R17). Nothing outside it is ever sent to Jev.
      def pool_ids
        Array(core["pool_ids"])
      end

      # The query text, decrypted on encrypted models. Only jobs read it.
      def query
        store.unseal(core) unless expired?
      end

      def search_query
        Search::Query.new(query)
      end

      def status
        return :expired if expired?
        return :cancelled if cancelled?
        return :paused if store.read(id, "status") == "paused"
        return :pending unless plan

        chunk_states.all? { |state| RESOLVED_CHUNKS.include?(state) } ? :complete : :running
      end

      def cancelled?
        return false if expired?
        return true if store.read(id, "status") == "cancelled"

        current = store.current_run_id(record_type, tenant_key, user_key, surface)
        current.present? && current != id
      end

      def paused? = status == :paused
      def complete? = status == :complete

      # Still streaming: not paused, cancelled, expired, or complete.
      def active?
        %i[pending running].include?(status)
      end

      def reserved?
        !%i[cancelled expired].include?(status)
      end

      def reserved_slots
        reserved? ? (plan ? candidate_ids.size : [ pool_ids.size, Truffler.config.rerank_depth ].min) : 0
      end

      def plan
        store.read(id, "plan") unless expired?
      end

      # The candidates the rerank judges: the snapshot after the awaited
      # encoding's filters, at most `rerank_depth`.
      def candidate_ids
        Array(plan&.fetch("candidate_ids", nil))
      end

      def chunk_ids(index)
        plan&.fetch("chunks", nil)&.at(index)
      end

      def chunk_count
        Array(plan&.fetch("chunks", nil)).size
      end

      def applied_filters
        Array(plan&.fetch("filters", nil))
      end

      # Filters the awaited encoding applied that were relaxed because they
      # left no candidate (see Search::Relaxation).
      def relaxed_labels
        Array(plan&.fetch("relaxed_labels", nil))
      end

      def chunk(index)
        store.read(id, "chunk/#{index}") unless expired?
      end

      def chunk_states
        Array.new(chunk_count) { |index| chunk(index)&.fetch("status", nil) || "pending" }
      end

      def chunk_resolved?(index)
        RESOLVED_CHUNKS.include?(chunk(index)&.fetch("status", nil))
      end

      def buckets
        empty = BUCKETS.index_with { [] }
        return empty unless %i[running complete paused].include?(status)

        limits = thresholds
        chunks = Array.new(chunk_count) { |index| chunk(index) }.compact.select { |entry| entry["status"] == "done" }
        chunks.sort_by { |entry| entry["seq"] }.each_with_object(empty) do |entry, buckets|
          entry["entries"].each { |id, score| buckets[SmartSearch.bucket_for(score, thresholds: limits)] << { id: id, score: score } }
        end
      end

      def promoted_ids
        found = buckets
        (found[:strong] + found[:possible]).map { |entry| entry[:id] }
      end

      # A bucket shows its pending state until every chunk resolved (R24).
      def pending?(bucket = nil)
        raise ArgumentError, "unknown bucket #{bucket}" if bucket && !BUCKETS.include?(bucket.to_sym)

        active?
      end

      def collapsed_by_default
        COLLAPSED_BY_DEFAULT
      end

      def collapsed?(bucket)
        COLLAPSED_BY_DEFAULT.include?(bucket.to_sym)
      end

      def no_strong_matches?
        complete? && buckets[:strong].empty?
      end

      # Stops the run and clears its buckets: pending chunk jobs make no Jev
      # call and an in-flight chunk's answers are discarded on return.
      def cancel!
        return false if expired?

        store.write(id, "status", "cancelled")
        chunk_count.times { |index| store.delete(id, "chunk/#{index}") }
        ping(SMART)
        true
      end

      def pause!(reason = nil)
        return false unless active?

        store.write(id, "status", "paused")
        Instrumentation.instrument(:smart_paused, run_id: id, record_type: record_type, reason: reason)
        ping(SMART)
        true
      end

      def plan!(candidate_ids:, chunk_size:, filters:, relaxed_labels: [])
        store.write(id, "plan", { "candidate_ids" => candidate_ids, "chunks" => candidate_ids.each_slice(chunk_size).to_a,
          "filters" => filters, "relaxed_labels" => relaxed_labels,
          "thresholds" => Truffler.config.smart_thresholds.transform_keys(&:to_s) })
      end

      # Appends one chunk's `[[id, score], ...]`, sorted by score within the
      # chunk. Returns false when the run was cancelled meanwhile.
      def append_chunk(index, entries)
        return false if cancelled? || expired?

        sorted = entries.each_with_index.sort_by { |(_, score), position| [ -score, position ] }.map(&:first)
        store.write(id, "chunk/#{index}", { "status" => "done", "seq" => store.next_seq(id), "entries" => sorted })
        true
      end

      def fail_chunk(index, error_class)
        return false if cancelled? || expired?

        store.write(id, "chunk/#{index}", { "status" => "failed", "error_class" => error_class })
        true
      end

      # A host section's state (`{status:, ...}`, status as a symbol);
      # `{status: :absent}` until something writes it.
      def section(name)
        state = (store.read(id, "section/#{section_name(name)}") unless expired?) || ABSENT
        state = state.with_indifferent_access
        state[:status] = state[:status].to_sym if state[:status].respond_to?(:to_sym)
        state
      end

      def write_section(name, state)
        return false if expired?

        store.write(id, "section/#{section_name(name)}", state.to_h.deep_stringify_keys)
        true
      end

      # Writes a section's state and pings the searcher to reload it. The
      # provider backup job (U11) reports :pending, :results, :empty, and
      # :unavailable through here. A cancelled or expired run ignores it.
      def update_section(name, state)
        return false if expired? || cancelled?

        write_section(name, state)
        ping(section_name(name))
        true
      end

      def provider_section
        section(PROVIDER)
      end

      def provider_section=(state)
        write_section(PROVIDER, state)
      end

      def ping(section)
        Broadcaster.ping(user_key, run_id: id, section: section)
      end

      # The `smart` prop a host renders; data only, no records.
      def to_h
        found = buckets
        current = status
        { run_id: id, status: current, reserved: reserved?, reserved_slots: reserved_slots, paused: current == :paused,
          explicit_action: explicit_action, buckets: found, pending: BUCKETS.index_with { active? },
          collapsed: collapsed_by_default, no_strong_matches: current == :complete && found[:strong].empty?,
          promoted_ids: (found[:strong] + found[:possible]).map { |entry| entry[:id] }, applied_filters: applied_filters,
          relaxed_labels: relaxed_labels, sections: { provider: provider_section.to_h.symbolize_keys } }
      end

      def as_json(*)
        to_h.as_json
      end

      private

      def section_name(name)
        name = name.to_s
        raise ArgumentError, "section #{SMART} belongs to the rerank" if name == SMART
        raise ArgumentError, "section names are lowercase words" unless name.match?(/\A[a-z_]+\z/)

        name
      end

      def thresholds
        (plan&.fetch("thresholds", nil) || Truffler.config.smart_thresholds).transform_keys(&:to_sym)
      end
    end
  end
end
