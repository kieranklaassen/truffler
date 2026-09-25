require "test_helper"

class TrufflerTest < Truffler::TestCase
  test "defines a version" do
    assert_match(/\A\d+\.\d+\.\d+/, Truffler::VERSION)
  end

  test "the default test client refuses live calls" do
    assert_raises(Truffler::LiveCallInTest) do
      Truffler.config.client.ask(state: {}, questions: {})
    end
  end

  test "eager loads every file except optional adapters" do
    assert_nothing_raised { Zeitwerk::Loader.eager_load_namespace(Truffler) }
  end
end
