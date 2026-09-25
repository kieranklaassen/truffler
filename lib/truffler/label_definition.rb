module Truffler
  # One typed label question. Nouls store their probability, scores their
  # normalized position, and choices one row per option ("label:option") with
  # that option's probability. Choice options may be a callable of the tenant
  # key, which makes the vocabulary per-tenant.
  #
  # A label with `from:` is supplied by the host: its answer is read from the
  # record in the shape Jev answers normalize to and Jev is never asked. Its
  # question is optional and `version:` forces a refresh when its logic
  # changes. On any label, `watch:` names extra columns whose change
  # refreshes (or re-asks) just that label.
  class LabelDefinition
    TYPES = %i[noul choice score].freeze
    KEY = /\A[a-z][a-z0-9_]*\z/

    attr_reader :key, :type, :instructions, :filter_at, :boost, :watch, :version
    # Intent weight a filter decision adds to the KTD20 query vector (default 0).
    attr_reader :filter_weight

    def initialize(key, type, question: nil, criteria: nil, options: nil, legend: nil, filter_at: nil, boost: nil, filter_weight: 0.0,
      description: nil, from: nil, watch: nil, version: nil)
      @key = key.to_s
      @type = type.to_sym
      @instructions = question
      @criteria = criteria
      @options = options
      @legend = legend
      @filter_at = filter_at&.to_f
      @boost = boost&.to_f
      @filter_weight = Float(filter_weight)
      @description = description
      @from = from
      @watch = Array(watch).map(&:to_s)
      @version = version
      validate!
    end

    def supplied?
      !@from.nil?
    end

    # The label's wording for query encoding: the description, else the question, else the key.
    def description
      @description.presence || instructions.presence || key
    end

    def per_tenant?
      @options.respond_to?(:call)
    end

    def options(tenant_key = nil)
      options = per_tenant? ? @options.call(tenant_key) : @options
      options = Array(options).to_h { |option| [ option, nil ] } unless options.is_a?(Hash)
      raise DefinitionError, "#{key}: choice options for tenant #{tenant_key.inspect} are empty" if options.empty?

      options = options.to_h { |option, description| [ option.to_s, description ] }
      raise DefinitionError, "#{key}: the option name #{NO_OPTION} is reserved" if options.key?(NO_OPTION)

      options
    end

    def question(tenant_key = nil)
      wording = instructions.presence || description
      Questions.build do |questions|
        case type
        when :noul then questions.noul(key, instructions: wording, criteria: @criteria)
        when :choice then questions.choice(key, instructions: wording, criteria: options(tenant_key))
        when :score then questions.score(key, instructions: wording, criteria: @legend)
        end
      end.fetch(key)
    end

    # Stored supplied values change with their shape and version, never with
    # the Jev model. The description and option wording are digested too
    # because query encoding asks about them.
    def supplied_fingerprint(tenant_key = nil)
      Canonical.digest(supplied: true, type: type, options: (options(tenant_key) if type == :choice),
        levels: (levels if type == :score), description: description, version: version)
    end

    # {storage_key => value} read from the record, or nil when the host has
    # no answer. Raises InvalidSuppliedAnswer for a value out of shape.
    def supplied_values(record, tenant_key = nil)
      value = @from.call(record)
      return if value.nil?

      case type
      when :noul then { key => probability(value) }
      when :score then { key => level(value) }
      when :choice then choice_values(value, options(tenant_key).keys)
      end
    end

    def storage_keys(tenant_key = nil)
      type == :choice ? options(tenant_key).keys.map { |option| "#{key}:#{option}" } : [ key ]
    end

    # The label part of its Jev question id ("<tag>__<question_key>").
    def question_key
      key
    end

    private

    def levels
      Array(@legend).size
    end

    def probability(value)
      return value ? 1.0 : 0.0 if [ true, false ].include?(value)
      return value.to_f if value.is_a?(Numeric) && value.between?(0, 1)

      raise InvalidSuppliedAnswer, "#{key}: expected a probability from 0 to 1 or true/false, got #{value.class}"
    end

    def level(value)
      return value.to_f / (levels - 1) if value.is_a?(Integer) && value.between?(0, levels - 1)

      raise InvalidSuppliedAnswer, "#{key}: expected a level index from 0 to #{levels - 1}"
    end

    def choice_values(value, options)
      probabilities = value.is_a?(Hash) ? value.to_h { |option, share| [ option.to_s, share ] } : { value.to_s => 1.0 }
      unknown = probabilities.keys - options
      raise InvalidSuppliedAnswer, "#{key}: #{unknown.size} answer option(s) are not declared options" if unknown.any?

      options.to_h { |option| [ "#{key}:#{option}", probabilities.key?(option) ? probability(probabilities[option]) : 0.0 ] }
    end

    def validate!
      raise DefinitionError, "label #{key.inspect} must match #{KEY.source} without a double underscore" unless valid_key?
      raise DefinitionError, "label #{key.inspect} is reserved for lens dimensions" if key == Lenses::KEY_PREFIX
      raise DefinitionError, "#{key}: type must be one of #{TYPES.join(', ')}" unless TYPES.include?(type)
      validate_supplied!
      raise DefinitionError, "#{key}: choice labels need options:" if type == :choice && @options.blank?
      raise DefinitionError, "#{key}: score labels need a legend: of at least two levels" if type == :score && levels < 2

      question unless per_tenant?
    rescue ArgumentError => error
      raise DefinitionError, error.message
    end

    def validate_supplied!
      unless supplied?
        raise DefinitionError, "#{key}: a question is required" if instructions.blank?
        raise DefinitionError, "#{key}: version: needs from:" unless @version.nil?

        return
      end
      raise DefinitionError, "#{key}: from: must be callable with the record" unless @from.respond_to?(:call)
    end

    def valid_key?
      KEY.match?(key) && !key.include?(Questions::SEPARATOR)
    end
  end
end
