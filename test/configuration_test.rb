require "test_helper"

class ConfigurationTest < Truffler::TestCase
  test "configure yields the configuration with defaults" do
    Truffler.reset_config!

    Truffler.configure do |config|
      assert_equal "jev-latest", config.model
      assert_equal 1_200, config.requests_per_minute
      assert_in_delta 0.042, config.cost_per_million_tokens
    end
  end

  test "TYPESAFE_REQUESTS_PER_MINUTE overrides the per-minute limit" do
    config = Truffler::Configuration.new(env: { "TYPESAFE_REQUESTS_PER_MINUTE" => "600" })

    assert_equal 600, config.requests_per_minute
  end

  test "a blank TYPESAFE_REQUESTS_PER_MINUTE keeps the default" do
    config = Truffler::Configuration.new(env: { "TYPESAFE_REQUESTS_PER_MINUTE" => "" })

    assert_equal 1_200, config.requests_per_minute
  end

  test "cost_for prices input tokens at the configured rate" do
    assert_in_delta 0.042, Truffler.config.cost_for(1_000_000)
  end

  test "falls back to a memory cache and a silent logger outside Rails" do
    config = Truffler::Configuration.new

    assert_kind_of ActiveSupport::Cache::MemoryStore, config.cache_store
    assert_same config.cache_store, config.cache_store
    assert_kind_of Logger, config.logger
  end
end
