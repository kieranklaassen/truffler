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
      end
    end

    private

    def truffler_enqueue_labeling
      definition = self.class.truffler_definition
      watched = [ *definition.fields, definition.tenant_column ].compact
      return unless previously_new_record? || saved_changes.keys.intersect?(watched)

      Labeling::Queue.new(self.class).enqueue(self)
    end

    def truffler_forget
      Labeling::Queue.new(self.class).forget(self)
    end
  end
end
