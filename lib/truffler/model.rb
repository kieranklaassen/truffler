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
        self.truffler_definition = definition
        Truffler.registry.register(self)
        definition
      end
    end
  end
end
