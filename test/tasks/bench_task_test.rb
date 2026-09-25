require "test_helper"
require "open3"

class BenchTaskTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  test "truffler:bench prints only the JSON report on stdout" do
    stdout, stderr, status = Open3.capture3({ "MODE" => "replay", "OUT" => nil }, Gem.ruby, "-S", "rake", "truffler:bench", chdir: ROOT)

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert report.dig("checks", "passed")
  end
end
