module Truffler
  module Search
    # A time window named in a search query (R16, R18): computed here from
    # the query tokens and a clock, never asked of Jev. Matching needs no
    # clock, so the phrase is part of the query; `window(now)` resolves it
    # to `[from, to]`, where `to` is nil for "until now".
    #
    #   today, yesterday, this week, last week, this month, last month,
    #   past|last N day(s)|week(s), since monday..sunday
    #
    # Weeks start on `Date.beginning_of_week` (Monday by default). Only the
    # first phrase in a query counts; a quoted phrase is exact text.
    TimePhrase = Data.define(:name, :positions, :resolver) do
      def self.find(tokens)
        tokens.each_index do |start|
          PATTERNS.each do |pattern|
            phrase = pattern.call(tokens, start)
            return phrase if phrase
          end
        end
        nil
      end

      def window(now)
        resolver.call(now)
      end

      def range(now)
        from, to = window(now)
        TimeRange.new(name: name, from: from, to: to)
      end

      def self.fixed(words, name, &resolver)
        lambda do |tokens, start|
          new(name: name, positions: (start...start + words.size).to_a, resolver: resolver) if tokens[start, words.size] == words
        end
      end

      def self.rolling(tokens, start)
        return unless %w[past last].include?(tokens[start]) && tokens[start + 1].to_s.match?(/\A\d{1,3}\z/)

        count = Integer(tokens[start + 1], 10)
        unit = { "day" => :days, "days" => :days, "week" => :weeks, "weeks" => :weeks }[tokens[start + 2]]
        return unless unit && count.positive?

        name = "Last #{count} #{count == 1 ? unit.to_s.singularize : unit}"
        new(name: name, positions: [ start, start + 1, start + 2 ], resolver: ->(now) { [ now - count.public_send(unit), nil ] })
      end

      def self.since(tokens, start)
        wday = Date::DAYNAMES.map(&:downcase).index(tokens[start + 1]) if tokens[start] == "since"
        return unless wday

        new(name: "Since #{Date::DAYNAMES[wday]}", positions: [ start, start + 1 ],
          resolver: ->(now) { [ (now - ((now.wday - wday) % 7).days).beginning_of_day, nil ] })
      end

      PATTERNS = [
        method(:rolling),
        method(:since),
        fixed(%w[today], "Today") { |now| [ now.beginning_of_day, nil ] },
        fixed(%w[yesterday], "Yesterday") { |now| [ now.yesterday.beginning_of_day, now.beginning_of_day ] },
        fixed(%w[this week], "This week") { |now| [ now.beginning_of_week, nil ] },
        fixed(%w[last week], "Last week") { |now| [ now.prev_week.beginning_of_week, now.beginning_of_week ] },
        fixed(%w[this month], "This month") { |now| [ now.beginning_of_month, nil ] },
        fixed(%w[last month], "Last month") { |now| [ now.prev_month.beginning_of_month, now.beginning_of_month ] }
      ].freeze
    end
  end
end
