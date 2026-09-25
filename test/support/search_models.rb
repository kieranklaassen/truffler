# Search fixtures over the emails and embedded_notes tables. InboxEmail has
# a local keyword source and a sender blind-index lookup; RecallNote adds
# embeddings so the text term can be blended in.
class InboxEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject, :body, :sender_name
    label :needs_action, :noul, question: "Does this email need the reader to act or reply?", filter_at: 0.6, boost: 2.0
    label :urgent, :noul, question: "Is this email time-sensitive?", boost: 2.0
    label :category, :choice, question: "Which category fits this email?", options: %w[billing travel other], filter_at: 0.5
    label :importance, :score, question: "How important is this email?", legend: { 0 => "Ignorable", 1 => "Worth a look", 2 => "Must read" }
    keyword :subject, :body
    exact :sender, ->(scope, token) { scope.where(sender_email: token) }
    order :received_at, :desc
    surface :palette, explicit_action: :row
  end
end

class RecallNote < ActiveRecord::Base
  self.table_name = "embedded_notes"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :title, :body
    label :spam, :noul, question: "Is this note spam?"
    label :pinned, :noul, question: "Is this note pinned?", boost: 1.0
    keyword :title
    embeddings dimensions: 3
  end
end

module Truffler
  module Test
    module SearchHelpers
      def label!(record, values)
        now = Time.current
        values.each do |key, value|
          Truffler::Records::Label.create!(record_type: record.class.polymorphic_name, record_id: record.id,
            tenant_key: record.account_id.to_s, label_key: key.to_s, value: value, fingerprint: "fp", labeled_at: now)
        end
        record
      end

      def inbox_email!(labels: {}, account_id: 1, subject: "Hello", body: "", sender_email: nil, received_at: Time.current)
        label!(InboxEmail.create!(account_id: account_id, subject: subject, body: body, sender_email: sender_email,
          received_at: received_at), labels)
      end

      def cache_encoding!(model, query, tenant: "1", **attributes)
        Truffler::Search::EncodingCache.new.write(model, query, Truffler::Search::Encoding.new(**attributes), tenant_key: tenant)
      end

      def search(model, query, tenant: 1, scope: model.all, **options)
        model.truffler(query, tenant: tenant, scope: scope, user: "user-1", **options)
      end
    end
  end
end
