require "fileutils"

module Truffler
  module Benchmark
    # Synthetic stream-shaped emails with ground-truth labels, gold queries
    # tagged intent or exact_text, and injection twins (a clean record's copy
    # with embedded instructions whose labels must not change, R34).
    class Dataset
      FILES = { records: "records.jsonl", gold: "gold.jsonl", injections: "injection.jsonl" }.freeze

      Record = Data.define(:id, :tenant, :subject, :body, :sender_name, :sender_email, :received_at, :truth)
      Gold = Data.define(:id, :kind, :tenant, :query, :expected_ids)
      Injection = Data.define(:id, :clean_id, :query, :record)

      attr_reader :records, :gold, :injections

      def self.load(dir)
        read = ->(name) { File.readlines(File.join(dir, FILES.fetch(name)), chomp: true).reject(&:blank?).map { |line| JSON.parse(line) } }
        new(
          records: read.(:records).map { |row| record(row) },
          gold: read.(:gold).map { |row| Gold.new(**row.symbolize_keys) },
          injections: read.(:injections).map { |row| Injection.new(**row.symbolize_keys.merge(record: record(row["record"]))) }
        )
      end

      def self.record(row)
        Record.new(**row.symbolize_keys)
      end

      def initialize(records:, gold:, injections:)
        @records = records
        @gold = gold
        @injections = injections
      end

      def write(dir)
        FileUtils.mkdir_p(dir)
        { records: records, gold: gold, injections: injections }.each do |name, rows|
          File.write(File.join(dir, FILES.fetch(name)), rows.map { |row| "#{Canonical.json(serialize(row))}\n" }.join)
        end
      end

      # Clean records plus injection twins, the set that gets labeled.
      def labeled_records
        records + injections.map(&:record)
      end

      def tenants
        records.map(&:tenant).uniq.sort
      end

      def summary
        { "records" => records.size, "tenants" => tenants.size,
          "gold" => gold.group_by(&:kind).transform_values(&:size).sort.to_h,
          "injection_twins" => injections.size }
      end

      private

      def serialize(row)
        row.to_h.transform_values { |value| value.is_a?(Data) ? value.to_h : value }
      end
    end
  end
end
