require "fileutils"

module Truffler
  module Clients
    # Records or replays any adapter's responses, keyed by the SHA-256 of the
    # canonical request JSON ({model, state, questions}). A recording stores
    # only the answers, the answering model, and usage, never the request.
    #
    # Modes: :replay (a miss raises CassetteMiss), :record (always calls the
    # inner client), :auto (replays hits, records misses).
    class Cassette < Base
      MODES = %i[replay record auto].freeze

      def initialize(inner, dir:, mode: :replay)
        raise ArgumentError, "cassette mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode.to_sym)

        @inner = inner
        @dir = dir.to_s
        @mode = mode.to_sym
      end

      def perform(state:, questions:, model:)
        hash = Canonical.digest(model: model, state: state, questions: questions)
        path = File.join(@dir, "#{hash}.json")
        return JSON.parse(File.read(path)) if @mode != :record && File.exist?(path)
        raise CassetteMiss, "no recording #{hash} in #{@dir}" if @mode == :replay || @inner.nil?

        record(path, hash, @inner.perform(state: state, questions: questions, model: model))
      end

      private

      def record(path, hash, response)
        response = normalize(response)
        stored = response.slice("answers", "model", "usage").merge("request_hash" => hash)
        FileUtils.mkdir_p(@dir)
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, "#{Canonical.json(stored)}\n")
        File.rename(temp, path)
        stored
      end
    end
  end
end
