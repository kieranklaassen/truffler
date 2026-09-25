module Truffler
  module Model
    extend ActiveSupport::Concern

    included do
      class_attribute :truffler_definition, instance_accessor: false, instance_predicate: false
    end

    class_methods do
      # With a block, declares what truffler labels and searches. With a
      # query, runs a keystroke search:
      #
      #   Email.truffler("needs action", tenant: account.id, scope: Email.all, user: current_user)
      def truffler(query = nil, **options, &block)
        return truffler_search(query, **options) unless block || (query.nil? && options.empty?)
        raise ArgumentError, "truffler needs a declaration block or a query" unless block
        raise ArgumentError, "truffler takes a declaration block or a query, not both" if query || options.any?

        definition = Definition.new(self)
        Definition::DSL.new(definition).instance_exec(&block)
        definition.validate!
        install_truffler_callbacks unless truffler_definition
        self.truffler_definition = definition
        Truffler.registry.register(self)
        definition
      end

      def truffler_search(query, tenant: nil, scope: nil, user: nil, suppressed: [], surface: nil, **options)
        Search::Keystroke.new(self, query, tenant: tenant, scope: scope, user: user, suppressed: suppressed, surface: surface,
          **options).call
      end

      # Records matching the same search that arrived after `since`, usually
      # a result's watermark (R25).
      def jev_new_matches_count(query, tenant: nil, scope: nil, user: nil, since:, suppressed: [])
        Search::Keystroke.new(self, query, tenant: tenant, scope: scope, user: user, suppressed: suppressed).count(since: since)
      end

      # The explicit action (R22): starts a Smart run and returns it,
      # already reserved. The keystroke list stays as it was.
      def jev_smart_search(query, tenant: nil, scope: nil, user: nil, surface: nil, suppressed: [])
        SmartSearch.start(self, query, tenant: tenant, scope: scope, user: user, surface: surface, suppressed: suppressed)
      end

      # Cancels the searcher's in-flight Smart run, as on a query edit or a
      # chip change (R24).
      def jev_cancel_smart_search(tenant: nil, user: nil, surface: nil)
        SmartSearch.cancel(self, tenant: tenant, user: user, surface: surface)
      end

      private

      def install_truffler_callbacks
        after_commit :truffler_enqueue_labeling, on: %i[create update]
        after_commit :truffler_forget, on: :destroy
        after_commit :truffler_enqueue_embedding, on: %i[create update]
      end
    end

    private

    def truffler_enqueue_labeling
      definition = self.class.truffler_definition
      watched = [ *definition.fields, definition.tenant_column ].compact
      return unless previously_new_record? || saved_changes.keys.intersect?(watched)

      truffler_expire_labels unless previously_new_record?
      Labeling::Queue.new(self.class).enqueue(self)
    end

    # Stored values keep serving search until the relabel lands; clearing the
    # fingerprints is what makes the labeler ask every question again.
    def truffler_expire_labels
      Records::Label.where(record_type: self.class.polymorphic_name, record_id: id).update_all(fingerprint: "")
    end

    def truffler_forget
      Labeling::Queue.new(self.class).forget(self)
    end

    def truffler_enqueue_embedding
      definition = self.class.truffler_definition
      return unless Embeddings.managed?(definition)
      return unless previously_new_record? || saved_changes.keys.intersect?([ *definition.fields, definition.tenant_column ].compact)

      Jobs::EmbedJob.perform_later(self.class.polymorphic_name, id)
    end
  end
end
