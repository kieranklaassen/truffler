module Truffler
  # One typed label question. Nouls store their probability, scores their
  # normalized position, and choices one row per option ("label:option") with
  # that option's probability. Choice options may be a callable of the tenant
  # key, which makes the vocabulary per-tenant.
  class LabelDefinition
    TYPES = %i[noul choice score].freeze
    KEY = /\A[a-z][a-z0-9_]*\z/

    attr_reader :key, :type, :instructions, :filter_at, :boost

    def initialize(key, type, question:, criteria: nil, options: nil, legend: nil, filter_at: nil, boost: nil)
      @key = key.to_s
      @type = type.to_sym
      @instructions = question
      @criteria = criteria
      @options = options
      @legend = legend
      @filter_at = filter_at&.to_f
      @boost = boost&.to_f
      validate!
    end

    def per_tenant?
      @options.respond_to?(:call)
    end

    def options(tenant_key = nil)
      options = per_tenant? ? @options.call(tenant_key) : @options
      options = Array(options).to_h { |option| [ option, nil ] } unless options.is_a?(Hash)
      raise DefinitionError, "#{key}: choice options for tenant #{tenant_key.inspect} are empty" if options.empty?

      options.to_h { |option, description| [ option.to_s, description ] }
    end

    def question(tenant_key = nil)
      Questions.build do |questions|
        case type
        when :noul then questions.noul(key, instructions: instructions, criteria: @criteria)
        when :choice then questions.choice(key, instructions: instructions, criteria: options(tenant_key))
        when :score then questions.score(key, instructions: instructions, criteria: @legend)
        end
      end.fetch(key)
    end

    def storage_keys(tenant_key = nil)
      type == :choice ? options(tenant_key).keys.map { |option| "#{key}:#{option}" } : [ key ]
    end

    private

    def validate!
      raise DefinitionError, "label #{key.inspect} must match #{KEY.source} without a double underscore" unless valid_key?
      raise DefinitionError, "#{key}: type must be one of #{TYPES.join(', ')}" unless TYPES.include?(type)
      raise DefinitionError, "#{key}: a question is required" if instructions.blank?
      raise DefinitionError, "#{key}: choice labels need options:" if type == :choice && @options.blank?
      raise DefinitionError, "#{key}: score labels need a legend: of at least two levels" if type == :score && Array(@legend).size < 2

      question unless per_tenant?
    rescue ArgumentError => error
      raise DefinitionError, error.message
    end

    def valid_key?
      KEY.match?(key) && !key.include?(Questions::SEPARATOR)
    end
  end
end
