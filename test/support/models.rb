ActiveRecord::Schema.define do
  create_table :emails, force: true do |t|
    t.integer :account_id, null: false
    t.string :subject
    t.text :body
    t.string :sender_name
    t.string :sender_email
    t.datetime :received_at
    t.timestamps
  end

  create_table :secret_notes, force: true do |t|
    t.integer :account_id, null: false
    t.string :title
    t.text :body
    t.timestamps
  end
end

class Email < ActiveRecord::Base
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject, :body, :sender_name
    label :needs_action, :noul, question: "Does this email need the reader to act or reply?",
      criteria: { true => "Asks for a reply, a decision, a payment, or a task", false => "FYI, receipts, newsletters" },
      filter_at: 0.6, boost: 2.0
    label :urgent, :noul, question: "Is this email time-sensitive?", boost: 2.0
    label :category, :choice, question: "Which category fits this email?",
      options: { billing: "Invoices, receipts, and payments", travel: "Trips and bookings", other: nil },
      filter_at: 0.5
    label :importance, :score, question: "How important is this email to the reader?",
      legend: { 0 => "Ignorable", 1 => "Worth a look", 2 => "Must read" }
    order :received_at, :desc
  end
end

class SecretNote < ActiveRecord::Base
  include Truffler::Model

  encrypts :body

  truffler do
    tenant :account_id
    reads :title, :body
    label :spam, :noul, question: "Is this note spam?"
  end
end
