module Truffler
  module Model
    extend ActiveSupport::Concern

    included do
      class_attribute :truffler_definition, instance_accessor: false, instance_predicate: false
    end

    class_methods do
      def truffler(&block)
        raise ArgumentError, "truffler needs a declaration block" unless block

        definition = Definition.new(self)
        Definition::DSL.new(definition).instance_exec(&block)
        definition.validate!
        install_truffler_callbacks unless truffler_definition
        self.truffler_definition = definition
        Truffler.registry.register(self)
        definition
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
