module Truffler
  class Railtie < Rails::Railtie
    rake_tasks do
      Dir[File.expand_path("../tasks/**/*.rake", __dir__)].each { |file| load file }
    end

    generators do
      require "generators/truffler/install/install_generator"
    end
  end
end
