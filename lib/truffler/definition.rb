module Truffler
  # Everything a model declares in its `truffler do ... end` block.
  class Definition
    EXPLICIT_ACTIONS = %i[enter key row].freeze
    DEFAULT_EMBEDDINGS = { model: "text-embedding-3-small", dimensions: 256 }.freeze

    attr_reader :model, :fields, :labels, :exact_sources, :providers, :surfaces, :watch_columns
    attr_accessor :tenant_column, :keyword, :embeddings, :order, :arrived_at_column

    def initialize(model)
      @model = model
      @fields = []
      @labels = {}
      @exact_sources = {}
      @providers = {}
      @surfaces = {}
      @watch_columns = []
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

    def supplied_labels
      labels.values.select(&:supplied?)
    end

    # Columns whose change relabels every label: the column-backed fields,
    # the tenant column, and the model-level `watch` columns. Method-backed
    # fields never show up in saved_changes, so they need `watch`.
    def relabel_columns
      [ *fields, tenant_column, *watch_columns ].compact
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

    # Field values as Jev request state: strings cut to max_chars so one long
    # record cannot crowd out a batch, everything else as JSON.
    def request_fields(record, max_chars:)
      field_values(record).transform_values { |value| value.is_a?(String) ? value[0, max_chars] : value.as_json }
    end

    # Newest first: by arrival when the table has that column, then by primary key.
    def arrival_order
      order = model.column_names.include?(arrived_at_column) ? { arrived_at_column => :desc } : {}
      order.merge(model.primary_key => :desc)
    end

    def encrypted_fields
      Array(model.try(:encrypted_attributes)).map(&:to_s) & fields
    end

    # Column checks wait for the table: a model declared at boot on a fresh
    # database is checked on its first labeling or search instead.
    def validate!
      raise DefinitionError, "#{model.name}: declare the fields Jev reads with `reads`" if fields.empty?

      @columns_deferred = !table_available?
      validate_columns! unless @columns_deferred
      check_embeddings if embeddings
    end

    def validate_columns!
      return if @columns_checked

      if @columns_deferred
        return unless table_available?

        model.reset_column_information
      end
      check_columns([ tenant_column, *fields, *Array(keyword).grep(String), *watch_columns, *labels.values.flat_map(&:watch) ].compact.uniq)
      @columns_checked = true
    end

    DEFAULT_RANKING = { label: 1.0, text: 1.0, keyword: 0.5, exact: 1.0, min_similarity: 0.0 }.freeze
    DEFAULT_WEAK_BELOW = 3

    attr_writer :ranking, :weak_below

    # KTD20 blend weights for keystroke scoring, tuned by the benchmark (R36).
    def ranking
      DEFAULT_RANKING.merge(@ranking || {})
    end

    # Fewer keystroke results than this count as weak (R19, R21).
    def weak_below
      @weak_below || DEFAULT_WEAK_BELOW
    end

    attr_accessor :index_if, :index_scope

    # config.tenant_enabled is asked only for tenant-scoped models; an
    # unscoped model is always enabled.
    def tenant_enabled?(tenant_key)
      check = Truffler.config.tenant_enabled
      return true if check.nil? || !scoped?

      check.call(model, tenant_key) ? true : false
    end

    # Whether the after-commit hooks, Queue, and EmbedJob handle this record:
    # its tenant is enabled and `index_if` (when declared) accepts it.
    def indexable?(record)
      tenant_enabled?(tenant_key_for(record)) && (index_if.nil? || index_if.call(record) ? true : false)
    end

    # The relation the batch paths (backfills, sweeps) page over.
    def index_relation(relation = model.all)
      index_scope ? index_scope.call(relation) : relation
    end

    # The tenant a backfill spend ledger row belongs to: the tenant for
    # scoped models under backfill_spend_cap_scope :tenant, else nil (app-wide).
    def ledger_tenant(tenant_key)
      tenant_key if scoped? && Truffler.config.backfill_spend_cap_scope.to_sym == :tenant
    end

    attr_writer :invite_on_pending_encoding

    # Whether a model with a `keyword` source shows the Smart search row while
    # the query's encoding is in flight (AE10). Default true.
    def invite_on_pending_encoding
      @invite_on_pending_encoding.nil? || @invite_on_pending_encoding
    end

    private

    def table_available?
      model.connection.data_source_exists?(model.table_name)
    rescue ActiveRecord::ActiveRecordError
      false
    end

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

      def watch(*columns)
        @definition.watch_columns.concat(columns.map(&:to_s))
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

      def ranking(**weights)
        unknown = weights.keys - DEFAULT_RANKING.keys
        raise DefinitionError, "ranking: unknown weights #{unknown.join(', ')}" if unknown.any?

        @definition.ranking = weights.transform_values { |weight| Float(weight) }
      end

      def weak_below(count)
        @definition.weak_below = Integer(count)
      end

      def index_if(callable)
        raise DefinitionError, "index_if must be callable with the record" unless callable.respond_to?(:call)

        @definition.index_if = callable
      end

      def index_scope(callable)
        raise DefinitionError, "index_scope must be callable with a relation" unless callable.respond_to?(:call)

        @definition.index_scope = callable
      end

      def invite_on_pending_encoding(enabled)
        @definition.invite_on_pending_encoding = enabled ? true : false
      end
    end
  end
end
