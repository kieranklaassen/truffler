# A model indexed for only some of its records: archived notes are never
# labeled or embedded (index_if for single records, index_scope for the
# batch paths).
ActiveRecord::Schema.define do
  create_table :tenant_notes, force: true do |t|
    t.integer :account_id, null: false
    t.string :title
    t.boolean :archived, null: false, default: false
    t.timestamps
  end
end

class TenantNote < ActiveRecord::Base
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :title
    label :spam, :noul, question: "Is this note spam?"
    embeddings
    index_if ->(note) { !note.archived }
    index_scope ->(relation) { relation.where(archived: false) }
  end
end
