module Truffler
  module Lenses
    # One lens question behind the LabelDefinition interface, so the labeler,
    # request builder, label vectors, and query encoding treat it like a
    # declared label. `key` is its storage key ("lens:<id>:<label>"); in Jev
    # requests it is asked as "lens<id>__<label>", which cannot collide with a
    # declared key because declared keys never hold a double underscore.
    class LensLabel
      attr_reader :lens_id, :label, :key, :type, :instructions

      def initialize(lens_id, label, question)
        @lens_id = lens_id
        @label = label.to_s
        @question = question.deep_dup.freeze
        @key = Lenses.label_key(lens_id, @label)
        @type = question.fetch("type").to_sym
        @instructions = question["instructions"]
      end

      def question_key
        "#{KEY_PREFIX}#{lens_id}#{Questions::SEPARATOR}#{label}"
      end

      def question(_tenant_key = nil)
        @question.deep_dup
      end

      def options(_tenant_key = nil)
        @question["criteria"].to_h.transform_keys(&:to_s)
      end

      def option_names(tenant_key = nil)
        options(tenant_key).compact
      end

      # The lens question, wording included, is already in its fingerprint.
      def encoding_wording(_tenant_key = nil) = nil

      def storage_keys(tenant_key = nil)
        type == :choice ? options(tenant_key).keys.map { |option| "#{key}:#{option}" } : [ key ]
      end

      def per_tenant?
        false
      end

      def supplied?
        false
      end

      def description = instructions

      def filter_at = nil
      def boost = nil
      def filter_weight = 0.0
    end
  end
end
