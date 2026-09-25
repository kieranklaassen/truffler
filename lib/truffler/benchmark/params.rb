require "yaml"

module Truffler
  module Benchmark
    # The tunable knobs (R36). A params file only needs the keys it changes;
    # everything else keeps the default. Unknown keys raise so an optimizer's
    # typo cannot silently tune nothing.
    class Params
      DEFAULTS = {
        "labeling" => {
          "batch_size" => 10,
          "agreement_batch_sizes" => [ 5, 10, 20 ],
          "agreement_sample_per_tenant" => 20,
          "agreement_tolerance" => 0.15,
          "agreement_floor" => 0.95
        },
        "search" => {
          "thresholds" => { "needs_action" => 0.6, "urgent" => nil, "category" => 0.5, "importance" => nil },
          "boosts" => { "needs_action" => 2.0, "urgent" => 1.5, "category" => nil, "importance" => 1.0 },
          "label_weight" => 1.0,
          "text_weight" => 0.0,
          "embeddings" => false,
          "encoding_deadline_ms" => 1000
        },
        "rerank" => {
          "depth" => 30
        },
        "injection" => {
          "label_tolerance" => 0.15
        }
      }.freeze

      def self.load(path = nil, overrides: {})
        loaded = path ? YAML.safe_load_file(path.to_s) || {} : {}
        new(loaded.deep_merge(overrides.deep_stringify_keys))
      end

      def initialize(values = {})
        check_keys(DEFAULTS, values)
        @values = DEFAULTS.deep_merge(values).deep_dup
        check_values
      end

      def to_h
        @values.deep_dup
      end

      def dig(*keys)
        @values.dig(*keys.map(&:to_s))
      end

      def batch_size
        dig(:labeling, :batch_size)
      end

      def agreement_batch_sizes
        [ 1, *dig(:labeling, :agreement_batch_sizes), batch_size ].uniq.sort
      end

      def threshold(label)
        dig(:search, :thresholds, label)
      end

      def boost(label)
        dig(:search, :boosts, label)
      end

      def rerank_depth
        dig(:rerank, :depth)
      end

      private

      def check_keys(defaults, values, prefix = nil)
        values.each do |key, value|
          name = [ prefix, key ].compact.join(".")
          raise ArgumentError, "unknown benchmark param #{name}" unless defaults.key?(key)

          check_keys(defaults[key], value, name) if defaults[key].is_a?(Hash) && value.is_a?(Hash)
        end
      end

      def check_values
        positive = { "labeling.batch_size" => batch_size, "rerank.depth" => rerank_depth }
        positive.each do |name, value|
          raise ArgumentError, "benchmark param #{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?
        end
      end
    end
  end
end
