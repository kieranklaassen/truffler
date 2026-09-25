module Truffler
  module Misses
    # Groups normalized queries by shared non-filler terms. The anchor term with
    # the most distinct users claims every unclaimed query containing it; a
    # cluster qualifies only when its queries came from enough distinct users,
    # and it names only terms that each cleared the same gate, so no single
    # user's wording leaves the log. Tokens with digits or "@" are dropped:
    # they are exact identifiers (R18), not intents.
    class Clusterer
      MAX_TERMS = 3
      FILLER = %w[
        a about after all an and any are as at be before by can do find for from get give has have how i in is it
        list me mine my of on or please search see show that the their them there these this those to was were
        what when where which who why will with without you your
      ].to_set.freeze

      def initialize(model, min_distinct_users:)
        @min = min_distinct_users
        noun = model.model_name.human.downcase
        @filler = FILLER | [ noun, noun.pluralize, *noun.split ]
      end

      # entries: [[normalized query, user digest or nil], ...]
      def clusters(entries)
        rows = entries.filter_map do |text, user|
          terms = terms_for(text)
          [ terms, user ] if terms.any?
        end
        claimed = Array.new(rows.size, false)

        gated_terms(rows).filter_map do |anchor|
          members = rows.each_index.select { |i| !claimed[i] && rows[i].first.include?(anchor) }
          users = members.filter_map { |i| rows[i].last }.to_set
          next if users.size < @min

          members.each { |i| claimed[i] = true }
          Cluster.new(terms: top_terms(rows.values_at(*members)), query_count: members.size, distinct_users: users.size)
        end
      end

      def terms_for(text)
        text.to_s.scan(/[[:alnum:]@._'-]+/).filter_map do |token|
          next if token.match?(/[\d@]/)

          term = token.delete("'").gsub(/\A[._-]+|[._-]+\z/, "").singularize
          term if term.length > 1 && !@filler.include?(term) && !@filler.include?(token)
        end.uniq
      end

      private

      def top_terms(rows)
        gated_terms(rows).first(MAX_TERMS)
      end

      # Terms seen from enough users, most users first, ties in reading order.
      def gated_terms(rows)
        users_by_term(rows).select { |_, users| users.size >= @min }.each_with_index
          .sort_by { |(_, users), position| [ -users.size, position ] }.map { |(term, _), _| term }
      end

      def users_by_term(rows)
        rows.each_with_object(Hash.new { |hash, term| hash[term] = Set.new }) do |(terms, user), index|
          terms.each { |term| index[term] << user if user }
        end
      end
    end
  end
end
