# Host-supplied label fixtures over the feedbacks table. The host has
# already classified each record (happyhappy's Classification answers), so
# SuppliedFeedback labels come entirely from `from:` and MixedFeedback adds
# one question Jev still answers.
ActiveRecord::Schema.define do
  create_table :feedbacks, force: true do |t|
    t.integer :account_id, null: false
    t.text :body
    t.string :sentiment
    t.float :anger
    t.integer :actionability
    t.string :author_role
    t.timestamps
  end
end

class SuppliedFeedback < ActiveRecord::Base
  self.table_name = "feedbacks"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :body
    label :sentiment, :choice, options: %w[positive neutral negative], from: ->(record) { record.sentiment },
      description: "the feedback's overall sentiment", watch: [ :sentiment ], filter_at: 0.5
    label :anger, :noul, from: ->(record) { record.anger }, watch: [ :anger ], boost: 2.0
    label :actionability, :score, legend: %w[none some clear], from: ->(record) { record.actionability }
  end
end

class MixedFeedback < ActiveRecord::Base
  self.table_name = "feedbacks"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :body
    label :sentiment, :choice, options: %w[positive neutral negative], from: ->(record) { record.sentiment }, watch: [ :sentiment ]
    label :needs_reply, :noul, question: "Does this feedback ask for a reply?"
  end
end
