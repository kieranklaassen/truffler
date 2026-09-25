module Truffler
  class Error < StandardError; end

  class DefinitionError < Error; end
  class SuppliedLabelFailed < Error; end
  class MissingScope < Error; end
  class LiveCallInTest < Error; end
  class IncompleteAnswers < Error; end
  class CassetteMiss < Error; end

  # Carries the budget's hint of how many seconds until a retry can succeed.
  class BudgetExhausted < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      @retry_after = retry_after
      super(message)
    end
  end

  class TenantMismatch < Error; end
  class NotAuthorized < Error; end
  class InvalidLens < Error; end
  class LensSpendCapExceeded < Error; end
  class InvalidSuppliedAnswer < Error; end

  # Carries the HTTP status and the original error's class name only, never a
  # response body, which can echo record text back.
  class ClientError < Error
    attr_reader :status, :error_class

    def self.from(error)
      new(status: status_of(error), error_class: error.class.name)
    end

    def self.status_of(error)
      status = error.status if error.respond_to?(:status)
      response = error.response if error.respond_to?(:response)
      status ||= response.status if response.respond_to?(:status)
      status ||= response[:status] if response.is_a?(Hash)
      status&.to_i
    end

    def initialize(status: nil, error_class: nil)
      @status = status
      @error_class = error_class
      super([ "Jev request failed", status && "(status #{status})", error_class ].compact.join(" "))
    end
  end
end
