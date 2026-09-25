module Truffler
  # The replayable benchmark behind `rake truffler:bench` (KTD17). Everything
  # it reads lives under bench/: params.yml, synthetic fixtures, and the
  # committed cassettes. No step touches real data (R35).
  module Benchmark
    ROOT = File.expand_path("../../bench", __dir__)
    REPORT_VERSION = 1

    # Stands in for a metric whose unit has not landed yet, so the report
    # keeps every key and says what it waits for instead of failing.
    NotAvailable = Data.define(:requires) do
      def to_h
        { "status" => "not_available_yet", "requires" => requires }
      end

      def as_json(*)
        to_h
      end
    end

    def self.path(*parts)
      File.join(ROOT, *parts)
    end

    def self.not_available?(value)
      value.is_a?(NotAvailable) || (value.is_a?(Hash) && value["status"] == "not_available_yet")
    end
  end
end
