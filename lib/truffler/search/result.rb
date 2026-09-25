module Truffler
  module Search
    # One keystroke search, carrying every host UI contract: records, chips
    # (R20), the Smart search invite row (R21), the encoding status, the
    # watermark for "N new matches" (R25), the surface's explicit action
    # (R23), and per-record score breakdowns for debugging.
    class Result
      ENCODING_STATUSES = %i[cached pending none].freeze
      INVITE_REASONS = %i[weak empty encoding_pending].freeze
      SCORE_COLUMNS = { label: "truffler_label_score", text: "truffler_text_score", keyword: "truffler_keyword_score",
        exact: "truffler_exact_score" }.freeze

      attr_reader :records, :query, :encoding, :encoding_status, :watermark, :explicit_action, :sources, :invite_row

      def initialize(records:, query:, encoding:, encoding_status:, watermark:, explicit_action:, sources:, invite_row:, weights:, recount:)
        @records = records
        @query = query
        @encoding = encoding
        @encoding_status = encoding_status
        @watermark = watermark
        @explicit_action = explicit_action
        @sources = sources
        @invite_row = invite_row
        @weights = weights
        @recount = recount
      end

      def ids
        records.map(&:id)
      end

      # Applied filters, then boosts, as `{key:, label:, kind:, name:}`.
      def chips
        return [] unless encoding

        filters = encoding.filters.keys.map { |key| chip(key, :filter) }
        filters + (encoding.boosts.keys - encoding.filters.keys).map { |key| chip(key, :boost) }
      end

      def score(record)
        find(record)&.attributes&.fetch("truffler_score", nil)&.to_f
      end

      # The weighted terms that summed to the record's score.
      def breakdown(record)
        found = find(record)
        return {} unless found

        SCORE_COLUMNS.to_h { |term, name| [ term, found.attributes.fetch(name, 0.0).to_f ] }.merge(total: score(found))
      end

      # Each intent label's share of the label term, `key => w_label * weight
      # * value`. Loaded on first use, so the keystroke itself stays one query.
      def contributions(record)
        id = record.respond_to?(:id) ? record.id : record
        (@contributions ||= load_contributions).fetch(id.to_s, {})
      end

      def new_matches_count
        @recount.call(watermark)
      end

      def promoted_ids(run)
        return [] unless run

        ids & Array(run.promoted_ids)
      end

      def smart_ranking_paused?(run = nil)
        run&.status&.to_sym == :paused
      end

      private

      def find(record)
        id = record.respond_to?(:id) ? record.id : record
        records.find { |item| item.id == id }
      end

      def chip(key, kind)
        label, option = Encoding.split_key(key)
        title = label.split(":").last.humanize
        name = option ? "#{title}: #{option}" : title
        { key: key, label: label, kind: kind, name: name }
      end

      def load_contributions
        intent = encoding&.intent_vector.to_h
        return {} if intent.empty? || records.empty?

        model = records.first.class
        rows = Records::Label.where(record_type: model.polymorphic_name, record_id: ids, label_key: intent.keys)
          .pluck(:record_id, :label_key, :value)
        rows.each_with_object(Hash.new { |hash, id| hash[id] = {} }) do |(id, key, value), map|
          map[id.to_s][key] = @weights[:label] * intent[key] * value
        end
      end
    end
  end
end
