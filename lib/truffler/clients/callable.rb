module Truffler
  module Clients
    # Wraps a host client that responds to `evaluate(state:, schema:)`, such as
    # Cora's TypeSafeClient. The schema is the question hash in wire shape. The
    # pinned model is passed only when the host's method accepts `model:`.
    class Callable < Base
      def initialize(host)
        @host = host
      end

      def perform(state:, questions:, model:)
        if accepts_model?
          @host.evaluate(state: state, schema: questions, model: model)
        else
          @host.evaluate(state: state, schema: questions)
        end
      end

      private

      def accepts_model?
        @host.method(:evaluate).parameters.any? { |kind, name| name == :model || kind == :keyrest }
      end
    end
  end
end
