module Truffler
  module Test
    class HostClient
      attr_reader :calls

      def initialize(response: nil, error: nil)
        @response = response
        @error = error
        @calls = []
      end

      def evaluate(state:, schema:)
        @calls << { state: state, schema: schema }
        raise @error if @error

        @response
      end
    end
  end
end
