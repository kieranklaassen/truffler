module Truffler
  module Labeling
    # Labels claimed record states of one tenant. It asks Jev only the labels
    # that are missing or whose fingerprint is stale, packs records into as
    # few requests as the budget allows, stores each answer as numeric label
    # rows, and marks states labeled as each request lands, so a failure
    # partway leaves finished records finished.
    class Labeler
      Result = Data.define(:labeled, :requests, :cost, :demoted)

      attr_reader :model, :client, :budget

      def initialize(model, client: Truffler.config.client, budget: Budget.new)
        @model = model
        @client = client
        @budget = budget
      end

      def label(states, priority:)
        return Result.new(labeled: 0, requests: 0, cost: 0.0, demoted: false) if states.empty?

        tenant_key = tenant_key_of(states)
        records = load_records(states)
        vocabulary = definition.vocabulary
        fingerprints = vocabulary.fingerprints(tenant_key: tenant_key)
        version = vocabulary.version(tenant_key: tenant_key)
        states_by_id = states.index_by { |state| state.record_id.to_s }

        stored = stored_fingerprints(records)
        pending = records.map { |record| [ record, stale_keys(stored[record.id.to_s].to_h, fingerprints, tenant_key) ] }
        current, pending = pending.partition { |_, keys| keys.empty? }
        Records::RecordState.mark_labeled(current.map { |record, _| states_by_id[record.id.to_s].id }, version: version)

        requests = RequestBuilder.new(definition, tenant_key: tenant_key).build(pending)
        cost = 0.0
        requests.each_with_index do |request, index|
          decision = budget.acquire(priority: priority, tenant_key: (tenant_key if index.zero?),
            records: index.zero? ? pending.size : 1)
          return Result.new(labeled: current.size, requests: index, cost: cost, demoted: true) if decision.demoted?
          raise BudgetExhausted, "no Jev budget for #{priority} labeling" if decision.denied?

          answers = client.ask(state: request.state, questions: request.questions, priority: decision.priority)
          cost += answers.usage&.cost.to_f
          store(request, answers, fingerprints, tenant_key, version, states_by_id)
        end

        Result.new(labeled: records.size, requests: requests.size, cost: cost, demoted: false)
      end

      private

      def definition
        model.truffler_definition
      end

      def record_type
        model.polymorphic_name
      end

      def tenant_key_of(states)
        tenants = states.map(&:tenant_key).uniq
        raise TenantMismatch, "labeling holds records from exactly one tenant" if tenants.size > 1

        tenants.first
      end

      def load_records(states)
        records = model.where(model.primary_key => states.map(&:record_id)).to_a
        found = records.map { |record| record.id.to_s }
        gone = states.reject { |state| found.include?(state.record_id.to_s) }
        Records::RecordState.where(id: gone.map(&:id)).delete_all if gone.any?
        records
      end

      def stale_keys(stored, fingerprints, tenant_key)
        definition.labels.values.reject do |label|
          label.storage_keys(tenant_key).all? { |key| stored[key] == fingerprints[label.key] }
        end.map(&:key)
      end

      def stored_fingerprints(records)
        rows = Records::Label.where(record_type: record_type, record_id: records.map(&:id)).pluck(:record_id, :label_key, :fingerprint)
        rows.each_with_object({}) { |(id, key, print), map| (map[id.to_s] ||= {})[key] = print }
      end

      def store(request, answers, fingerprints, tenant_key, version, states_by_id)
        now = Time.current
        rows = request.entries.flat_map do |tag, (record, keys)|
          keys.flat_map do |key|
            label_rows(definition.label(key), Questions.tagged_id(tag, key), answers, tenant_key).map do |label_key, value|
              { record_type: record_type, record_id: record.id, tenant_key: tenant_key, label_key: label_key,
                value: value, fingerprint: fingerprints[key], labeled_at: now }
            end
          end
        end

        Records::Label.transaction do
          request.entries.each_value do |record, keys|
            keys.each { |key| Records::Label.where(record_type: record_type, record_id: record.id).for_label(key).delete_all }
          end
          Records::Label.insert_all!(rows) if rows.any?
          ids = request.entries.values.map { |record, _| states_by_id[record.id.to_s].id }
          Records::RecordState.mark_labeled(ids, version: version)
        end
      end

      def label_rows(label, id, answers, tenant_key)
        case label.type
        when :noul then [ [ label.key, answers.noul(id) ] ]
        when :score then [ [ label.key, answers.score(id) ] ]
        when :choice then label.options(tenant_key).keys.map { |option| [ "#{label.key}:#{option}", answers.probability(id, option) ] }
        end
      end
    end
  end
end
