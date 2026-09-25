module Truffler
  module Records
    # One numeric answer per record and label key. Choice labels store one row
    # per option as "label:option".
    class Label < ActiveRecord::Base
      self.table_name = "truffler_labels"

      scope :for_label, ->(key) { where(label_key: key).or(where("label_key LIKE ?", "#{sanitize_sql_like(key)}:%")) }
    end
  end
end
