# Provider backup fixtures. GmailEmail mirrors Cora: encrypted-style mail
# with no local text source and Gmail as the backup. LocalProviderEmail has a
# keyword source, so weak local results depend on the keystroke count.
module Truffler
  module Test
    # A scripted Gmail: per-tenant mailboxes searched by substring, or a
    # raised error. Records every call's keys.
    class FakeGmail
      class << self
        attr_writer :current

        def current
          @current ||= new
        end
      end

      attr_reader :calls
      attr_accessor :error

      def initialize(mailboxes = {})
        @mailboxes = mailboxes.transform_keys(&:to_s)
        @calls = []
      end

      def call(query, tenant:, user:)
        @calls << { query: query, tenant: tenant, user: user }
        raise error if error

        @mailboxes.fetch(tenant.to_s, []).select { |message| message[:subject].downcase.include?(query.downcase) }
      end
    end

    # The minimal Smart run the provider backup needs (see Truffler::Providers).
    class FakeRun
      attr_reader :id, :model, :query, :candidate_ids, :tenant_key, :user_key, :sections, :updates
      attr_accessor :cancelled

      @runs = {}

      class << self
        def find(id)
          @runs[id.to_s]
        end

        def store(run)
          @runs[run.id.to_s] = run
        end

        def clear
          @runs.clear
        end
      end

      def initialize(model:, query:, tenant_key: "1", user_key: "user-1", candidate_ids: [], sections: {})
        @id = SecureRandom.hex(8)
        @model = model
        @query = query
        @tenant_key = tenant_key
        @user_key = user_key
        @candidate_ids = candidate_ids
        @sections = sections
        @updates = []
        self.class.store(self)
      end

      def update_section(section, state)
        @updates << [ section, state ]
        @sections = @sections.merge(section => state)
      end

      def cancelled?
        cancelled == true
      end
    end
  end
end

class GmailEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject, :body
    label :needs_action, :noul, question: "Does this email need the reader to act or reply?", filter_at: 0.6
    provider :gmail, label: "Gmail", search: ->(query, tenant:, user:) { Truffler::Test::FakeGmail.current.call(query, tenant: tenant, user: user) }
    order :received_at, :desc
  end
end

class LocalProviderEmail < ActiveRecord::Base
  self.table_name = "emails"
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :subject, :body
    label :needs_action, :noul, question: "Does this email need the reader to act or reply?", boost: 2.0
    keyword :subject, :body
    provider :gmail, label: "Gmail", search: ->(query, tenant:, user:) { Truffler::Test::FakeGmail.current.call(query, tenant: tenant, user: user) }
    order :received_at, :desc
  end
end
