module Truffler
  module Benchmark
    # The benchmark's own model. Its declaration is applied per run from the
    # params, so thresholds, boosts, and embeddings are the tuned knobs.
    class Email < ActiveRecord::Base
      include Truffler::Model

      self.table_name = "truffler_bench_emails"

      CATEGORIES = {
        billing: "Invoices, receipts, and payments", travel: "Trips, bookings, and check-ins",
        work: "Colleagues, projects, and approvals", personal: "Friends and family", newsletter: "Subscriptions and digests"
      }.freeze

      def self.create_table!
        connection.create_table(table_name, force: true) do |t|
          t.integer :tenant_id, null: false
          t.string :subject
          t.text :body
          t.string :sender_name
          t.string :sender_email
          t.datetime :received_at
          t.timestamps
        end
        reset_column_information
      end

      def self.declare!(params)
        truffler do
          tenant :tenant_id
          reads :subject, :body, :sender_name
          keyword :subject, :body, :sender_email
          label :needs_action, :noul, question: "Does this email need the reader to act or reply?",
            criteria: { true => "Asks for a reply, a decision, a payment, or a task", false => "FYI, receipts, newsletters" },
            filter_at: params.threshold(:needs_action), boost: params.boost(:needs_action)
          label :urgent, :noul, question: "Is this email time-sensitive?",
            filter_at: params.threshold(:urgent), boost: params.boost(:urgent)
          label :category, :choice, question: "Which category fits this email?", options: CATEGORIES,
            filter_at: params.threshold(:category), boost: params.boost(:category)
          label :importance, :score, question: "How important is this email to the reader?",
            legend: { 0 => "Ignorable", 1 => "Worth a look", 2 => "Must read" },
            filter_at: params.threshold(:importance), boost: params.boost(:importance)
          embeddings if params.dig(:search, :embeddings)
          order :received_at, :desc
          arrived_at :received_at
        end
      end
    end
  end
end
