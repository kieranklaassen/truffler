ActiveRecord::Schema.define do
  create_table :feed_messages, force: true do |t|
    t.integer :account_id, null: false
    t.text :body
    t.string :author
    t.datetime :arrived_at
    t.timestamps
  end
end

class FeedMessage < ActiveRecord::Base
  include Truffler::Model

  truffler do
    tenant :account_id
    reads :body, :author
    label :sentiment, :choice, question: "What is the author's mood?", options: %w[happy neutral angry]
    label :relevant, :noul, question: "Is this message about the product?"
    arrived_at :arrived_at
  end
end

module Truffler
  module Test
    # Shared setup for lens tests: a fake drafting model, a fake Jev client,
    # a keyed-digest secret, and a host hook that lets admins change lenses.
    module LensHelpers
      User = Struct.new(:id, :admin, :account_id, keyword_init: true)

      DUTCH_QUESTION = { key: "language", type: "choice", instructions: "Which language is the message written in?",
                         options: %w[dutch other] }.freeze

      def self.included(base)
        base.setup do
          Truffler.config.secret_key_base = "test-secret-key-base"
          @generator = Truffler::Lenses::FakeGenerator.new
          @jev = Truffler::Clients::Fake.new
          Truffler.configure do |config|
            config.client = @jev
            config.lenses.generator = @generator
            config.lenses.authorize_lens = ->(user, _scope) { user&.admin }
          end
        end
      end

      def admin
        @admin ||= User.new(id: 1, admin: true, account_id: 1)
      end

      def member(id = 2, account_id: 1)
        User.new(id: id, admin: false, account_id: account_id)
      end

      def script_dutch(*extra_questions)
        @generator.draft(/dutch/i, name: "Happy Dutch speakers", reuse: [ "sentiment" ],
          questions: [ DUTCH_QUESTION, *extra_questions ])
      end

      def feed_message(body, account: 1, at: Time.current, author: "someone")
        FeedMessage.create!(account_id: account, body: body, author: author, arrived_at: at)
      end

      def dutch_draft(scope: Truffler::Lenses::Scope.tenant("1"))
        script_dutch
        Truffler::Lenses::Drafter.draft("happy people who speak Dutch", model: FeedMessage, scope: scope)
      end

      def dutch_lens(scope: Truffler::Lenses::Scope.tenant("1"), by: admin)
        Truffler::Lenses::Activator.activate(dutch_draft(scope: scope), by: by)
      end

      def answer_language_by_body
        @jev.answer(:language) { |tag, state| state.dig("records", tag, "body").to_s.include?("Hallo") ? "dutch" : "other" }
      end
    end
  end
end
