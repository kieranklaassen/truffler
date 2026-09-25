module Truffler
  module Search
    # A resolved time phrase: records whose `arrived_at` column is at or
    # after `from` and, when `to` is set, before it. Shown as the chip
    # `{key: "time", kind: :time}` and dropped by suppressing "time".
    TimeRange = Data.define(:name, :from, :to) do
      def self.key = "time"
    end
  end
end
