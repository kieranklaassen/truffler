require "test_helper"
require "json"
require "rubocop"
require "rails/generators/test_case"
require "generators/truffler/install/install_generator"
require "generators/truffler/upgrade/upgrade_generator"

# Every file the install and upgrade generators write lands in a host app
# that likely runs rubocop-rails-omakase, so the rendered output must pass it.
class TemplateStyleTest < Rails::Generators::TestCase
  destination File.expand_path("../../tmp/generator_style", __dir__)
  setup :prepare_destination

  OMAKASE = <<~YAML.freeze
    inherit_gem: { rubocop-rails-omakase: rubocop.yml }

    AllCops:
      TargetRubyVersion: 3.2
      NewCops: disable
  YAML

  def generate(generator, args = [])
    self.class.tests generator
    run_generator args
  end

  def offenses
    config = File.join(destination_root, ".rubocop.yml")
    File.write(config, OMAKASE)
    files = Dir[File.join(destination_root, "**/*.rb")].sort
    assert_operator files.size, :>=, 1
    output, = capture_io { RuboCop::CLI.new.run([ "--config", config, "--format", "json", "--cache", "false", *files ]) }
    JSON.parse(output).fetch("files").flat_map do |file|
      file["offenses"].map { |offense| "#{File.basename(file['path'])}:#{offense.dig('location', 'line')} #{offense['cop_name']}: #{offense['message']}" }
    end
  end

  test "0.1.6: install templates pass rubocop-rails-omakase with default and optional flags" do
    [ [], %w[--record-id-type uuid], %w[--vector-dimensions 1536] ].each do |args|
      prepare_destination
      generate Truffler::Generators::InstallGenerator, args

      assert_empty offenses, "install #{args.join(' ')}"
    end
  end

  test "0.1.6: every upgrade migration template passes rubocop-rails-omakase" do
    previous = Truffler::Generators::UpgradeGenerator.schema_connection
    Truffler::Generators::UpgradeGenerator.schema_connection = -> { raise ActiveRecord::ConnectionNotEstablished }
    generate Truffler::Generators::UpgradeGenerator

    assert_equal 3, Dir[File.join(destination_root, "db/migrate/*.rb")].size
    assert_empty offenses
  ensure
    Truffler::Generators::UpgradeGenerator.schema_connection = previous
  end
end
