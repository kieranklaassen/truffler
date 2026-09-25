module Truffler
  # The privacy allowlist for anything the gem logs, instruments, or stores
  # about a call: ids, counts, tokens, cost, model, latency, digests, and error
  # class names. Every other key is dropped, so record and query text cannot
  # leak through a payload by accident.
  module Redaction
    KEYS = %i[
      priority model cost input_tokens tokens_estimated latency_ms error_class status outcome reason
      record_type tenant_key user_key surface section sources vocabulary_version label_key
    ].to_set.freeze
    SUFFIXES = %w[_id _ids _count _digest _ms].freeze

    module_function

    def safe(payload)
      payload.to_h.select { |key, _| allowed?(key) }
    end

    def allowed?(key)
      key = key.to_sym
      KEYS.include?(key) || SUFFIXES.any? { |suffix| key.end_with?(suffix) }
    end
  end
end
