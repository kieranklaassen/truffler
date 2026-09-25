$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "truffler"
require "minitest/autorun"
require "active_support/test_case"
require "active_job/test_helper"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = ActiveSupport::Logger.new(nil)

module Truffler
  class TestCase < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      Truffler.reset_config!
      Truffler.configure do |config|
        config.client = Test::LiveCallGuard.new
        config.cache_store = ActiveSupport::Cache::MemoryStore.new
        config.embedder = Test::EmbedderGuard.new
      end
    end

    teardown do
      Test::Database.clean
    end

    def drain_jobs(limit: 20)
      limit.times do
        return if enqueued_jobs.empty?

        perform_enqueued_jobs
      end
      flunk "jobs kept enqueuing after #{limit} rounds"
    end

    def capture_notifications(pattern)
      payloads = []
      callback = ->(_name, _start, _finish, _id, payload) { payloads << payload }
      ActiveSupport::Notifications.subscribed(callback, pattern) { yield }
      payloads
    end
  end
end
