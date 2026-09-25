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
        @labels = vocabulary.labels_for(tenant_key: tenant_key, all_users: true)
        fingerprints = vocabulary.fingerprints(tenant_key: tenant_key, all_users: true)
        version = vocabulary.version(tenant_key: tenant_key, all_users: true)
        states_by_id = states.index_by { |state| state.record_id.to_s }

        stored = stored_fingerprints(records)
        askable = askable_labels
        pending = records.map { |record| [ record, stale_keys(stored[record.id.to_s].to_h, fingerprints, tenant_key, askable) ] }
        current, pending = pending.partition { |_, keys| keys.empty? }
        Records::RecordState.mark_labeled(current.map { |record, _| states_by_id[record.id.to_s].id }, version: version)
        Embeddings::LabelVector.new(model).write(current.map { |record, _| record.id }, tenant_key: tenant_key)

        requests = RequestBuilder.new(definition, tenant_key: tenant_key, labels: @labels).build(pending)
        cost = 0.0
        requests.each_with_index do |request, index|
          decision = budget.acquire(priority: priority, tenant_key: (tenant_key if index.zero?),
            records: index.zero? ? pending.size : 1)
          return Result.new(labeled: current.size, requests: index, cost: cost, demoted: true) if decision.demoted?
          raise BudgetExhausted, "no Jev budget for #{priority} labeling" if decision.denied?

          answers = client.ask(state: request.state, questions: request.questions, priority: decision.priority)
          cost += answers.usage&.cost.to_f
          charge_lenses(request, answers.usage&.cost.to_f)
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

      def stale_keys(stored, fingerprints, tenant_key, askable)
        askable.reject do |label|
          label.storage_keys(tenant_key).all? { |key| stored[key] == fingerprints[label.key] }
        end.map(&:key)
      end

      # Every label except those of lenses at their spend cap (R43).
      def askable_labels
        lens_labels = @labels.values.grep(Lenses::LensLabel)
        @lenses = nil
        return @labels.values if lens_labels.empty?

        @lenses = Lenses::Lens.where(id: lens_labels.map(&:lens_id).uniq).index_by(&:id)
        @labels.values.reject { |label| label.is_a?(Lenses::LensLabel) && @lenses[label.lens_id]&.spend_cap_reached? }
      end

      # Splits a request's cost over its questions and adds each lens's share
      # to that lens's spend.
      def charge_lenses(request, cost)
        return if @lenses.blank? || cost.zero?

        keys = request.entries.values.flat_map { |_, keys| keys }
        keys.filter_map { |key| @labels[key] }.grep(Lenses::LensLabel).group_by(&:lens_id).each do |lens_id, asked|
          @lenses[lens_id]&.record_spend!(cost * asked.size / keys.size)
        end
      end

      def stored_fingerprints(records)
        rows = Records::Label.where(record_type: record_type, record_id: records.map(&:id)).pluck(:record_id, :label_key, :fingerprint)
        rows.each_with_object({}) { |(id, key, print), map| (map[id.to_s] ||= {})[key] = print }
      end

      def store(request, answers, fingerprints, tenant_key, version, states_by_id)
        now = Time.current
        rows = request.entries.flat_map do |tag, (record, keys)|
          keys.flat_map do |key|
            label = @labels.fetch(key)
            label_rows(label, Questions.tagged_id(tag, label.question_key), answers, tenant_key).map do |label_key, value|
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
          Embeddings::LabelVector.new(model).write(request.entries.values.map { |record, _| record.id }, tenant_key: tenant_key)
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
