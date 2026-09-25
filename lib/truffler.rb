require "active_support"
require "active_support/core_ext"
require "active_record"
require "active_job"
require "zeitwerk"

require_relative "truffler/version"
require_relative "truffler/errors"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect("ruby_llm_typesafe" => "RubyLLMTypeSafe")
loader.ignore("#{__dir__}/generators", "#{__dir__}/tasks")
loader.ignore("#{__dir__}/truffler/errors.rb", "#{__dir__}/truffler/railtie.rb")
loader.do_not_eager_load("#{__dir__}/truffler/clients/ruby_llm_typesafe.rb")
loader.inflector.inflect("ruby_llm_embedder" => "RubyLLMEmbedder")
loader.do_not_eager_load("#{__dir__}/truffler/embeddings/ruby_llm_embedder.rb")
loader.inflector.inflect("ruby_llm_generator" => "RubyLLMGenerator")
loader.do_not_eager_load("#{__dir__}/truffler/lenses/ruby_llm_generator.rb")
loader.setup

module Truffler
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def reset_config!
      @config = Configuration.new
    end

    def registry
      @registry ||= Registry.new
    end
  end
end

require_relative "truffler/railtie" if defined?(Rails::Railtie)
