require "test_helper"

class SearchResultTest < Truffler::TestCase
  include Truffler::Test::SearchHelpers

  Run = Struct.new(:status, :promoted_ids)

  test "carries the surface's explicit action and the watermark" do
    freeze_time do
      result = search(InboxEmail, "hello", surface: :palette)

      assert_equal :row, result.explicit_action
      assert_equal Time.current, result.watermark
    end
    assert_nil search(InboxEmail, "hello").explicit_action
  end

  test "an undeclared surface raises" do
    assert_raises(Truffler::DefinitionError) { search(InboxEmail, "hello", surface: :sidebar) }
  end

  test "promoted ids and paused smart ranking read from a Smart run" do
    shown = inbox_email!(subject: "Invoice")
    inbox_email!(subject: "Invoice")
    result = search(InboxEmail, "invoice")

    assert_equal [ shown.id ], result.promoted_ids(Run.new(:running, [ shown.id, 999 ]))
    assert_empty result.promoted_ids(nil)
    assert result.smart_ranking_paused?(Run.new(:paused, []))
    assert_not result.smart_ranking_paused?(Run.new(:running, []))
    assert_not result.smart_ranking_paused?
  end

  test "chips list filters before boosts and name choice options" do
    inbox_email!(subject: "Invoice", labels: { "category:billing" => 0.9 })
    cache_encoding!(InboxEmail, "billing invoice", filters: { "category:billing" => 0.5 }, boosts: { urgent: 2.0 },
      keyword_tokens: %w[invoice])

    chips = search(InboxEmail, "billing invoice").chips

    assert_equal [
      { key: "category:billing", label: "category", kind: :filter, name: "Category: billing" },
      { key: "urgent", label: "urgent", kind: :boost, name: "Urgent" }
    ], chips
  end

  test "contributions are empty for records the intent does not touch" do
    record = inbox_email!(subject: "Invoice")

    assert_equal({}, search(InboxEmail, "invoice").contributions(record))
  end
end
