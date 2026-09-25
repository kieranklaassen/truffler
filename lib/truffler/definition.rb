module Truffler
  # Everything a model declares in its `truffler do ... end` block.
  class Definition
    EXPLICIT_ACTIONS = %i[enter key row].freeze
    DEFAULT_EMBEDDINGS = { model: "text-embedding-3-small", dimensions: 256 }.freeze

    attr_reader :model, :fields, :labels, :exact_sources, :providers, :surfaces
    attr_accessor :tenant_column, :keyword, :embeddings, :order, :arrived_at_column

    def initialize(model)
      @model = model
      @fields = []
      @labels = {}
      @exact_sources = {}
      @providers = {}
      @surfaces = {}
      @arrived_at_column = "created_at"
    end

    def add_label(label)
      raise DefinitionError, "label #{label.key} is declared twice" if labels.key?(label.key)

      labels[label.key] = label
    end

    def label(key)
      labels.fetch(key.to_s)
    end

    def label_keys
      labels.keys
    end

    def scoped?
      tenant_column.present?
    end

    def per_tenant_vocabulary?
      labels.each_value.any?(&:per_tenant?)
    end

    def vocabulary
      Vocabulary.new(self)
    end

    def tenant_key_for(record)
      record.public_send(tenant_column)&.to_s if scoped?
    end

    def field_values(record)
      fields.index_with { |field| record.public_send(field) }
    end

    def encrypted_fields
      Array(model.try(:encrypted_attributes)).map(&:to_s) & fields
    end

    def validate!
      raise DefinitionError, "#{model.name}: declare the fields Jev reads with `reads`" if fields.empty?

      check_columns([ tenant_column, *fields, *Array(keyword).grep(String) ].compact)
      check_embeddings if embeddings
    end

    private

    def check_columns(names)
      columns = model.attribute_names
      missing = names.reject { |name| columns.include?(name) || model.method_defined?(name) }
      raise DefinitionError, "#{model.name}: unknown attributes #{missing.join(', ')}" if missing.any?
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def check_embeddings
      return if embeddings.key?(:column) || embeddings[:allow_encrypted] || encrypted_fields.empty?

      raise DefinitionError, "#{model.name}: embeddings would send encrypted fields #{encrypted_fields.join(', ')} " \
        "to the embedding provider; pass allow_encrypted: true to opt in"
    end

    # The block API inside `truffler do ... end`.
    class DSL
      def initialize(definition)
        @definition = definition
      end

      def tenant(column)
        @definition.tenant_column = column.to_s
      end

      def reads(*fields)
        @definition.fields.concat(fields.map(&:to_s))
      end

      def label(key, type, **options)
        @definition.add_label(LabelDefinition.new(key, type, **options))
      end

      def keyword(*columns_or_callable)
        callable = columns_or_callable.first if columns_or_callable.one? && columns_or_callable.first.respond_to?(:call)
        @definition.keyword = callable || columns_or_callable.map(&:to_s)
      end

      def exact(name, callable)
        @definition.exact_sources[name.to_s] = callable
      end

      def embeddings(column: nil, **options)
        @definition.embeddings = column ? { column: column.to_s } : DEFAULT_EMBEDDINGS.merge(options)
      end

      def provider(name, label:, search:)
        @definition.providers[name.to_s] = { label: label, search: search }
      end

      def order(column, direction = :desc)
        @definition.order = [ column.to_s, direction.to_sym ]
      end

      def surface(name, explicit_action: :enter)
        unless EXPLICIT_ACTIONS.include?(explicit_action)
          raise DefinitionError, "surface #{name}: explicit_action must be one of #{EXPLICIT_ACTIONS.join(', ')}"
        end

        @definition.surfaces[name.to_s] = { explicit_action: explicit_action }
      end

      def arrived_at(column)
        @definition.arrived_at_column = column.to_s
      end
    end
  end
end
