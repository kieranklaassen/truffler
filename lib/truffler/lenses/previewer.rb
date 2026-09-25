module Truffler
  module Lenses
    # Answers a draft's questions on a sample of recent in-scope records in
    # one packed single-tenant Jev request, at encode priority and inside the
    # lens's spend cap (R40). `compare` runs an old and a new version on the
    # same sample and reports how the answers moved (R45).
    #
    # A preview holds record ids and numbers only; record text exists only in
    # the request state while the call runs.
    class Previewer
      MAX_EXAMPLES = 5

      Preview = Data.define(:tenant_key, :sample_ids, :types, :values, :buckets, :distribution, :means, :examples,
        :estimate, :cost)
      Estimate = Data.define(:records, :requests, :input_tokens, :cost_usd, :duration_seconds, :within_cap)
      Comparison = Data.define(:before, :after, :shift, :changed_count, :changed_ids, :added, :removed)

      def self.preview(target, **options)
        new.preview(target, **options)
      end

      def self.compare(draft, active, **options)
        new.compare(draft, active, **options)
      end

      attr_reader :client, :budget, :config

      def initialize(client: Truffler.config.client, budget: Budget.new, config: Truffler.config)
        @client = client
        @budget = budget
        @config = config
      end

      # target: a Draft, a Version, or a Lens (its active version). relation
      # narrows the sample to what the host's permission scope allows.
      def preview(target, sample: config.lenses.sample_size, ids: nil, tenant_key: nil, relation: nil, by: nil)
        draft = coerce(target)
        Validation.validate!(draft.questions, reused: draft.reused)
        scope = relation || draft.model.all
        tenant_key = resolve_tenant(draft, scope, tenant_key)
        records = sample_records(draft, scope, tenant_key, sample, ids)
        return empty_preview(draft, scope, tenant_key, records) if records.empty? || draft.questions.empty?

        state, questions, tags = build(draft, records)
        request_tokens = Tokens.estimate({ state: state, questions: questions })
        check_cap!(draft, config.cost_for(request_tokens))
        decision = budget.acquire(priority: :encode, user_key: (config.lenses.key_for(by) if by))
        raise BudgetExhausted, "no Jev budget for a lens preview" unless decision.granted?

        answers = client.ask(state: state, questions: questions, priority: :encode)
        cost = answers.usage&.cost.to_f
        draft.lens&.record_spend!(cost)
        summarize(draft, scope, tenant_key, tags, answers, request_tokens, cost)
      end

      def compare(draft, active, sample: config.lenses.sample_size, tenant_key: nil, relation: nil, by: nil)
        before = preview(active, sample: sample, tenant_key: tenant_key, relation: relation, by: by)
        after = preview(draft, ids: before.sample_ids, tenant_key: before.tenant_key, relation: relation, by: by)
        shared = before.types.keys.select { |label| after.types[label] == before.types[label] }
        common = before.sample_ids & after.sample_ids
        changed = common.select { |id| shared.any? { |label| before.buckets.dig(id, label) != after.buckets.dig(id, label) } }

        Comparison.new(before: before, after: after, shift: shared.index_with { |label| shift(before, after, label, common) },
          changed_count: changed.size, changed_ids: changed, added: after.types.keys - shared, removed: before.types.keys - shared)
      end

      private

      def coerce(target)
        case target
        when Draft then target
        when Version then target.to_draft
        when Lens then target.active_version&.to_draft || raise(InvalidLens, "lens #{target.id} has no active version")
        else raise ArgumentError, "cannot preview #{target.class.name}"
        end
      end

      def definition(draft)
        draft.model.truffler_definition
      end

      def resolve_tenant(draft, scope, tenant_key)
        tenant_key ||= draft.scope.tenant_key
        return tenant_key&.to_s if tenant_key || !definition(draft).scoped?

        scope.reorder(definition(draft).arrival_order).pick(definition(draft).tenant_column)&.to_s
      end

      def in_tenant(draft, scope, tenant_key)
        definition(draft).scoped? ? scope.where(definition(draft).tenant_column => tenant_key) : scope
      end

      def sample_records(draft, scope, tenant_key, sample, ids)
        model = draft.model
        records = in_tenant(draft, scope, tenant_key)
        records = records.where(model.primary_key => ids) if ids
        per_request = [ config.max_questions_per_request / [ draft.questions.size, 1 ].max, 1 ].max
        records.reorder(definition(draft).arrival_order).limit([ ids&.size || sample, per_request ].min).to_a
      end

      def build(draft, records)
        state_records = {}
        questions = {}
        tags = {}
        used = Tokens.estimate(Labeling::RequestBuilder::TASK)
        records.each.with_index(1) do |record, index|
          tag = Questions.tag("r", index)
          fields = definition(draft).request_fields(record, max_chars: config.max_field_chars)
          asked = draft.questions.to_h do |label, question|
            [ Questions.tagged_id(tag, label), question.merge("instructions" => { "record" => tag, "question" => question["instructions"] }) ]
          end
          used += Tokens.estimate(fields) + Tokens.estimate(asked)
          break if tags.any? && used > config.request_token_budget

          state_records[tag] = fields
          questions.merge!(asked)
          tags[tag] = record.id
        end
        [ { "task" => Labeling::RequestBuilder::TASK, "records" => state_records }, questions, tags ]
      end

      def check_cap!(draft, estimate)
        remaining = remaining_cap(draft)
        return if remaining.nil? || estimate <= remaining

        raise LensSpendCapExceeded, format("a lens preview needs about $%.6f but the lens has $%.6f left", estimate, remaining)
      end

      def remaining_cap(draft)
        draft.lens ? draft.lens.remaining_spend : config.lenses.spend_cap_usd
      end

      def summarize(draft, scope, tenant_key, tags, answers, request_tokens, cost)
        types = draft.question_types
        values = {}
        buckets = {}
        tags.each do |tag, record_id|
          values[record_id] = {}
          buckets[record_id] = {}
          draft.questions.each do |label, question|
            record_values, bucket = answer(label, question, answers, Questions.tagged_id(tag, label))
            values[record_id].merge!(record_values)
            buckets[record_id][label] = bucket
          end
        end

        distribution = draft.questions.to_h do |label, question|
          counts = bucket_names(question).index_with(0)
          buckets.each_value { |record| counts[record[label]] = counts[record[label]].to_i + 1 }
          [ label, counts ]
        end
        means = types.reject { |_, type| type == "choice" }.to_h do |label, _|
          [ label, values.values.sum { |record| record[label] } / values.size ]
        end
        examples = draft.questions.keys.index_with do |label|
          buckets.group_by { |_, record| record[label] }.transform_values { |rows| rows.first(MAX_EXAMPLES).map(&:first) }
        end

        Preview.new(tenant_key: tenant_key, sample_ids: tags.values, types: types, values: values, buckets: buckets,
          distribution: distribution, means: means, examples: examples, cost: cost,
          estimate: estimate(draft, scope, tenant_key, request_tokens / tags.size.to_f, cost))
      end

      # Returns [{storage suffix => value}, bucket]. Storage suffixes match
      # the label rows a lens writes: "label" or "label:option".
      def answer(label, question, answers, id)
        case question["type"]
        when "noul"
          value = answers.noul(id)
          [ { label => value }, value >= 0.5 ? "yes" : "no" ]
        when "score"
          value = answers.score(id)
          [ { label => value }, (value * (question["criteria"].size - 1)).round.to_s ]
        when "choice"
          options = question["criteria"].keys
          [ options.to_h { |option| [ "#{label}:#{option}", answers.probability(id, option) ] }, answers.choice(id) ]
        else raise InvalidLens, "#{label}: unknown question type #{question['type'].inspect}"
        end
      end

      def bucket_names(question)
        case question["type"]
        when "noul" then %w[yes no]
        when "score" then question["criteria"].each_index.map(&:to_s)
        when "choice" then question["criteria"].keys
        else raise InvalidLens, "unknown question type #{question['type'].inspect}"
        end
      end

      # Backfill estimate for every record the lens applies to: records ×
      # tokens per record × price, and requests at the backfill ceiling.
      def estimate(draft, scope, tenant_key, tokens_per_record, preview_cost)
        records = (draft.scope.app? ? scope : in_tenant(draft, scope, tenant_key)).count
        tokens = (records * tokens_per_record).ceil
        cost = config.cost_for(tokens)
        requests = (records / config.batch_size.to_f).ceil
        remaining = remaining_cap(draft)
        remaining -= preview_cost if remaining && !draft.lens
        Estimate.new(records: records, requests: requests, input_tokens: tokens, cost_usd: cost,
          duration_seconds: (requests / budget.ceiling(:backfill)).ceil, within_cap: remaining.nil? || cost <= remaining)
      end

      def empty_preview(draft, scope, tenant_key, records)
        Preview.new(tenant_key: tenant_key, sample_ids: records.map(&:id), types: draft.question_types, values: {}, buckets: {},
          distribution: draft.questions.transform_values { |question| bucket_names(question).index_with(0) }, means: {},
          examples: {}, cost: 0.0, estimate: estimate(draft, scope, tenant_key, 0, 0.0))
      end

      def shift(before, after, label, ids)
        names = before.distribution[label].keys | after.distribution[label].keys
        buckets = names.index_with { |name| after.distribution[label][name].to_i - before.distribution[label][name].to_i }
        mean = after.means[label] - before.means[label] if before.means.key?(label) && after.means.key?(label)
        { buckets: buckets, mean: mean, changed: ids.count { |id| before.buckets.dig(id, label) != after.buckets.dig(id, label) } }
      end
    end
  end
end
