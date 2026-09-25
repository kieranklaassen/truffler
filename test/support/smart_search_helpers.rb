module Truffler
  module Test
    # Records Action Cable pings instead of broadcasting them.
    class FakeCable
      attr_reader :pings

      def initialize(error: nil)
        @pings = []
        @error = error
      end

      def broadcast(stream, payload)
        raise @error if @error

        @pings << [ stream, payload ]
      end

      def sections
        pings.map { |_, payload| payload[:section] }
      end
    end

    class DeniedBudget
      attr_reader :calls

      def initialize
        @calls = []
      end

      def acquire(**options)
        @calls << options
        Truffler::Budget::Decision.new(:denied, options[:priority], :exhausted)
      end

      def admit(**options)
        @calls << options
        Truffler::Budget::Decision.new(:denied, options[:priority], :user_cap)
      end
    end

    module SmartSearchHelpers
      include SearchHelpers

      # Scores each rerank candidate from the first `subject => score` match.
      def rerank_client(scores = {}, default: 0.1)
        Truffler::Clients::Fake.new.answer(:relevance) do |tag, state|
          subject = state.dig("candidates", tag, "subject").to_s
          scores.find { |pattern, _| subject.include?(pattern) }&.last || default
        end
      end

      def rerank_calls(client)
        client.calls.select { |call| call[:state].key?("candidates") }
      end

      def smart(model = InboxEmail, query = "invoice", tenant: 1, scope: model.all, user: "user-1", **options)
        model.jev_smart_search(query, tenant: tenant, scope: scope, user: user, **options)
      end

      def smart_job_args
        smart_jobs = [ Truffler::Jobs::SmartSearchJob, Truffler::Jobs::RerankChunkJob ]
        enqueued_jobs.select { |job| smart_jobs.include?(job[:job]) }.map { |job| job[:args] }
      end
    end
  end
end
