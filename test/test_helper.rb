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
      end
    end

    teardown do
      Test::Database.clean
    end
  end
end
