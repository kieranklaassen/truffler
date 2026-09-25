module Truffler
  module Lenses
    # A named set of drafted label questions for one model and scope (R39).
    # The row mirrors its active version's questions, so search-time
    # visibility needs no join. Statuses: draft (never activated), proposed
    # (system-drafted from misses, awaiting approval), active, expired.
    class Lens < ActiveRecord::Base
      include SealedDescription

      self.table_name = "truffler_lenses"

      STATUSES = %w[draft proposed active expired].freeze

      HistoryEntry = Data.define(:number, :status, :label_keys, :reused, :restored_from, :created_by_digest, :created_at,
        :activated_by_digest, :activated_at)

      has_many :versions, -> { order(:number) }, class_name: "Truffler::Lenses::Version", foreign_key: :lens_id,
        inverse_of: :lens, dependent: :delete_all
      belongs_to :active_version, class_name: "Truffler::Lenses::Version", optional: true
      serialize :questions, coder: JSON
      serialize :reused_keys, coder: JSON

      validates :status, inclusion: { in: STATUSES }
      validates :scope_type, inclusion: { in: %w[app tenant user] }

      scope :active, -> { where(status: "active") }
      scope :proposed, -> { where(status: "proposed") }
      scope :for_model, ->(model) { where(record_type: model.polymorphic_name) }

      after_commit { Lenses.changed!(record_type) }

      def self.build_from(draft, status:, origin: "user", creator_digest: nil, proposal_digest: nil)
        new(record_type: draft.model.polymorphic_name, scope_type: draft.scope.type.to_s, scope_key: draft.scope.scope_key,
          tenant_key: draft.scope.tenant_key, name: draft.name, description: draft.description, status: status,
          origin: origin, creator_digest: creator_digest, proposal_digest: proposal_digest,
          spend_cap_usd: Lenses.settings.spend_cap_usd)
      end

      # Active lenses nobody has searched with for `after` stop applying
      # (R43). Their stored label rows stay until pruned.
      def self.expire_unused!(now: Time.current, after: Lenses.settings.expire_after)
        unused = active.where("COALESCE(last_used_at, updated_at) < ?", now - after)
        record_types = unused.distinct.pluck(:record_type)
        unused.update_all(status: "expired", updated_at: now).tap { record_types.each { |type| Lenses.changed!(type) } }
      end

      def model
        record_type.safe_constantize
      end

      def scope
        Scope.new(type: scope_type.to_sym, tenant_key: tenant_key, user_digest: (scope_key if scope_type == "user"))
      end

      def active? = status == "active"
      def proposed? = status == "proposed"
      def expired? = status == "expired"

      # {"lens:<id>:<label>" => wire-shape question} for the active version.
      def storage_questions
        questions.to_h.transform_keys { |label| Lenses.label_key(id, label) }
      end

      # {"lens:<id>:<label>" => LensLabel} for the active version.
      def labels
        questions.to_h.to_h { |label, question| [ Lenses.label_key(id, label), LensLabel.new(id, label, question) ] }
      end

      # The truffler_labels keys this lens writes: one per noul or score, one
      # per option for choices.
      def storage_keys
        questions.to_h.flat_map do |label, question|
          key = Lenses.label_key(id, label)
          question["type"] == "choice" ? question["criteria"].keys.map { |option| "#{key}:#{option}" } : [ key ]
        end
      end

      def remaining_spend
        spend_cap_usd && [ spend_cap_usd - spent_usd.to_f, 0.0 ].max
      end

      def spend_cap_reached?
        spend_cap_usd.present? && spent_usd.to_f >= spend_cap_usd
      end

      def would_exceed_cap?(cost)
        spend_cap_usd.present? && spent_usd.to_f + cost > spend_cap_usd
      end

      # Adds Jev spend atomically, so concurrent previews and backfill jobs
      # never lose an increment.
      def record_spend!(cost)
        return if cost.to_f.zero?

        self.class.where(id: id).update_all([ "spent_usd = spent_usd + ?, updated_at = ?", cost.to_f, Time.current ])
        self.spent_usd = self.class.where(id: id).pick(:spent_usd)
      end

      def draft_version
        versions.select(&:draft?).last
      end

      def add_version!(draft, by:, restored_from: nil)
        versions.create!(number: versions.maximum(:number).to_i + 1, description: draft.description, questions: draft.questions,
          reused_keys: draft.reused, fingerprint: draft.fingerprint, created_by_digest: Policy.digest_for(by),
          status: "draft", restored_from: restored_from)
      end

      # Drafts a new version from the same or an edited description. Search
      # keeps using the active version until the draft is activated.
      def regenerate(by:, description: nil, drafter: Drafter.new)
        Policy.authorize!(by, scope, model: model)
        text = description.presence || self.description
        raise InvalidLens, "lens #{id} has no readable description; pass description:" if text.blank?

        add_version!(drafter.draft(text, model: model, scope: scope, lens: self), by: by)
      end

      # Makes an earlier version's questions active again as a new version
      # that records where it came from, so history keeps every change.
      def restore!(number, by:)
        source = versions.find_by!(number: number)
        Policy.authorize!(by, scope, model: model)
        Activator.activate(add_version!(source.to_draft, by: by, restored_from: source.number), by: by)
      end

      def history
        versions.reload.map do |version|
          HistoryEntry.new(number: version.number, status: version.status, label_keys: version.questions.to_h.keys,
            reused: Array(version.reused_keys), restored_from: version.restored_from,
            created_by_digest: version.created_by_digest, created_at: version.created_at,
            activated_by_digest: version.activated_by_digest, activated_at: version.activated_at)
        end
      end

      # The declaration a developer pastes into the model to make this lens
      # part of the declared vocabulary (R43).
      def declaration_snippet
        questions.to_h.map do |label, question|
          line = "label :#{label}, :#{question['type']}, question: #{question['instructions'].to_s.inspect}"
          case question["type"]
          when "noul" then question["criteria"] ? "#{line}, criteria: #{question['criteria'].inspect}" : line
          when "choice" then "#{line}, options: #{question['criteria'].inspect}"
          when "score" then "#{line}, legend: #{question['criteria'].inspect}"
          else raise InvalidLens, "#{label}: unknown question type #{question['type'].inspect}"
          end
        end.join("\n")
      end

      def promote!(io: $stdout)
        declaration_snippet.tap { |snippet| io.puts(snippet) }
      end

      private

      def described_model
        model
      end
    end
  end
end
