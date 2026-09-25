require "digest"
require "json"

module Truffler
  # JSON with object keys sorted at every level, so key order never changes a
  # digest. Cassettes, fingerprints, and cache keys all hash through here.
  module Canonical
    module_function

    def json(value)
      JSON.generate(sort(value))
    end

    def digest(value)
      Digest::SHA256.hexdigest(json(value))
    end

    def sort(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, sort(item) ] }.sort.to_h
      when Array then value.map { |item| sort(item) }
      when Symbol then value.to_s
      else value
      end
    end
  end
end
