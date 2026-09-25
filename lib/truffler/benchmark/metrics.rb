module Truffler
  module Benchmark
    module Metrics
      EPSILON = 1e-9

      module_function

      def recall(expected, returned)
        expected = expected.to_a.uniq
        return 1.0 if expected.empty?

        (expected & returned.to_a).size / expected.size.to_f
      end

      def precision(expected, returned)
        returned = returned.to_a.uniq
        return expected.to_a.empty? ? 1.0 : 0.0 if returned.empty?

        (returned & expected.to_a).size / returned.size.to_f
      end

      # Nearest rank: the smallest value with at least pct% of values at or below it.
      def percentile(values, pct)
        return nil if values.empty?

        sorted = values.sort
        sorted[[ (pct / 100.0 * sorted.size).ceil - 1, 0 ].max]
      end

      def mean(values)
        values.empty? ? nil : values.sum / values.size.to_f
      end

      # single and packed map record id => { label => value }. Numeric values
      # agree within tolerance; choice picks (strings) agree when equal.
      def agreement(single, packed, tolerance:)
        compared = 0
        disagreements = []
        single.each do |record_id, labels|
          labels.each do |label, value|
            compared += 1
            other = packed.dig(record_id, label)
            disagreements << { record_id: record_id, label: label } unless agree?(value, other, tolerance)
          end
        end
        { agreement: compared.zero? ? 1.0 : (compared - disagreements.size) / compared.to_f,
          compared: compared, disagreements: disagreements }
      end

      def agree?(left, right, tolerance)
        return false if left.nil? || right.nil?
        return left == right unless left.is_a?(Numeric) && right.is_a?(Numeric)

        (left - right).abs <= tolerance + EPSILON
      end

      def adoptable?(agreement, floor:)
        agreement + EPSILON >= floor
      end
    end
  end
end
