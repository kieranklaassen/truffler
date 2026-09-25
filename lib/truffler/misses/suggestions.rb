module Truffler
  module Misses
    # Candidate label questions for developers (F4). Adding one stays a manual
    # step followed by backfill. Encrypted models without AR encryption have no
    # stored text, so their qualifying misses surface as digest-only counts.
    module Suggestions
      Suggestion = Data.define(:terms, :query_count, :distinct_users, :label_key, :question)

      module_function

      def for(record_type, tenant_key: ALL_TENANTS, min_distinct_users: nil)
        model = Misses.resolve(record_type)
        entries = Misses.entries(model, tenant_key: tenant_key)
        gate = Misses.gate(min_distinct_users)
        texts = entries.filter_map { |text, user, _| [ text, user ] if text }

        suggestions = Clusterer.new(model, min_distinct_users: gate).clusters(texts).map { |cluster| draft(model, cluster) }
        suggestions + digest_only(entries.reject(&:first), gate)
      end

      def report(record_type, io: $stdout, tenant_key: ALL_TENANTS)
        model = Misses.resolve(record_type)
        suggestions = self.for(model, tenant_key: tenant_key)
        return io.puts("No query miss clusters for #{model.name} from at least #{Misses.gate(nil)} distinct users.") if suggestions.empty?

        suggestions.each do |suggestion|
          terms = suggestion.terms.any? ? suggestion.terms.join(", ") : "(encrypted, no stored text)"
          io.puts "#{suggestion.query_count} queries from #{suggestion.distinct_users} users: #{terms}"
          io.puts %(  label :#{suggestion.label_key}, :noul, question: "#{suggestion.question}") if suggestion.question
        end
      end

      def draft(model, cluster)
        Suggestion.new(
          terms: cluster.terms, query_count: cluster.query_count, distinct_users: cluster.distinct_users,
          label_key: cluster.terms.join("_").parameterize(separator: "_"),
          question: "Is this #{model.model_name.human.downcase} about #{cluster.terms.to_sentence}?"
        )
      end

      def digest_only(entries, gate)
        entries.group_by(&:last).filter_map do |_, misses|
          users = misses.filter_map { |_, user, _| user }.uniq.size
          Suggestion.new(terms: [], query_count: misses.size, distinct_users: users, label_key: nil, question: nil) if users >= gate
        end
      end
    end
  end
end
