ActiveRecord::Schema.define do
  create_table :embedded_notes, force: true do |t|
    t.integer :account_id, null: false
    t.string :title
    t.text :body
    t.string :color
    t.timestamps
  end

  create_table :column_documents, force: true do |t|
    t.integer :account_id, null: false
    t.string :title
    t.text :embedding
    t.timestamps
  end
end

class EmbeddedNote < ActiveRecord::Base
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :title, :body
    label :spam, :noul, question: "Is this note spam?"
    embeddings
  end
end

# A host model that maintains its own vector column (R11), stored as JSON.
class ColumnDocument < ActiveRecord::Base
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :title
    label :spam, :noul, question: "Is this document spam?"
    embeddings column: :embedding
  end
end
