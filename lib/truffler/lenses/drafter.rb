module Truffler
  module Lenses
    # Turns a plain-language description into a validated Draft (R39, R44).
    # The drafting model sees the description, the declared and visible lens
    # vocabulary, and, for proposals, aggregated miss clusters. It never sees
    # record text: nothing here reads a record.
    class Drafter
      TASK = "Design label questions that let a search find the kind of records the description asks for. " \
        "Reuse an existing label (by key) wherever it already captures part of the description, and add a " \
        "new question only for what no existing label covers. Each new question must be atomic: one fact " \
        "about a single record, answerable from that record alone. Use noul for yes/no facts, choice for one " \
        "of several named options (include an `other` option when the list is open), and score for an ordered " \
        "scale of at most 10 levels. Never ask about dates, counts, or numeric comparisons. Keys are " \
        "lowercase snake_case. Leave fields that do not apply to a question's type empty.".freeze

      SCHEMA = {
        type: "object",
        additionalProperties: false,
        required: %w[name reuse questions],
        properties: {
          name: { type: "string" },
          reuse: { type: "array", items: { type: "string" } },
          questions: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: %w[key type instructions criteria_true criteria_false options levels],
              properties: {
                key: { type: "string" },
                type: { type: "string", enum: %w[noul choice score] },
                instructions: { type: "string" },
                criteria_true: { type: "string" },
                criteria_false: { type: "string" },
                options: {
                  type: "array",
                  items: {
                    type: "object",
                    additionalProperties: false,
                    required: %w[name description],
                    properties: { name: { type: "string" }, description: { type: "string" } }
                  }
                },
                levels: { type: "array", items: { type: "string" } }
              }
            }
          }
        }
      }.freeze

      def self.draft(description, **options)
        new.draft(description, **options)
      end

      def initialize(generator: Lenses.settings.generator_or_default, llm_model: Lenses.settings.drafter_model)
        @generator = generator
        @llm_model = llm_model
      end

      def draft(description, model:, scope:, lens: nil, clusters: [])
        raise InvalidLens, "a lens needs a description" if description.blank?
        check_scope!(model, scope)

        vocabulary = vocabulary_for(model, scope, lens)
        started = Instrumentation.monotonic_ms
        payload = { record_type: model.polymorphic_name, lens_id: lens&.id }
        begin
          response = @generator.generate(prompt: prompt(description, model, vocabulary, clusters), schema: SCHEMA,
            model: @llm_model)
          payload.merge!(model: response[:model], input_tokens: response[:input_tokens])
          draft = build(response.fetch(:draft).to_h.deep_stringify_keys, description, model, scope, lens, vocabulary)
          payload.merge!(question_count: draft.questions.size, outcome: "drafted")
          draft
        rescue Truffler::Error => error
          payload.merge!(outcome: "invalid", error_class: error.class.name)
          raise
        ensure
          Instrumentation.instrument(:lens_draft, payload.merge(latency_ms: Instrumentation.monotonic_ms - started))
        end
      end

      # {key => wire-shape question} the draft may reuse: declared labels and
      # the lens labels already visible in the scope, minus the lens being
      # regenerated.
      def vocabulary_for(model, scope, lens)
        definition = model.truffler_definition
        declared = definition.labels.to_h { |key, label| [ key, label.question(scope.tenant_key) ] }
        visible = Lenses.visible_lenses(model, tenant_key: scope.tenant_key, user_digest: scope.user_digest)
        visible = visible.reject { |other| other.id == lens&.id }
        declared.merge(visible.each_with_object({}) { |other, all| all.merge!(other.storage_questions) })
      end

      private

      def build(body, description, model, scope, lens, vocabulary)
        questions = questions_from(body["questions"])
        reused = Array(body["reuse"]).map(&:to_s).uniq
        Validation.validate!(questions, reused: reused, available: vocabulary.keys, declared: model.truffler_definition.label_keys)
        Draft.new(model: model, scope: scope, description: description, name: body["name"].presence || description.first(40),
          questions: questions, reused: reused, lens: lens)
      end

      def check_scope!(model, scope)
        raise ArgumentError, "#{model.name} is not a truffler model" unless model.try(:truffler_definition)
        return unless model.truffler_definition.scoped? && !scope.app? && scope.tenant_key.blank?

        raise ArgumentError, "#{scope.type} lenses on #{model.name} need a tenant key"
      end

      def prompt(description, model, vocabulary, clusters)
        JSON.generate(
          task: TASK,
          description: description,
          record_kind: model.model_name.human,
          existing_labels: vocabulary.map { |key, question| { key: key }.merge(question.slice("type", "instructions", "criteria")) },
          miss_clusters: clusters.map { |cluster| cluster.to_h.slice(:terms, :query_count, :distinct_users) }
        )
      end

      def questions_from(items)
        Questions.build do |questions|
          Array(items).each do |item|
            item = item.to_h
            key = item["key"].to_s
            instructions = item["instructions"].to_s
            case item["type"]
            when "noul" then questions.noul(key, instructions: instructions, criteria: noul_criteria(item))
            when "choice"
              options = Array(item["options"]).to_h { |option| [ option["name"].to_s, option["description"].presence ] }
              questions.choice(key, instructions: instructions, criteria: options)
            when "score" then questions.score(key, instructions: instructions, criteria: Array(item["levels"]).map(&:to_s))
            else raise InvalidLens, "#{key}: type must be one of #{Validation::TYPES.join(', ')}"
            end
          end
        end
      rescue ArgumentError => error
        raise InvalidLens, error.message
      end

      def noul_criteria(item)
        yes = item["criteria_true"].presence
        no = item["criteria_false"].presence
        { true => yes, false => no } if yes && no
      end
    end
  end
end
