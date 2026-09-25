module Truffler
  module Lenses
    # An unsaved lens proposal: new questions in the KTD2 wire shape keyed by
    # bare label key, plus the existing label keys it reuses. `lens` is set
    # when the draft regenerates an existing lens.
    Draft = Data.define(:model, :scope, :description, :name, :questions, :reused, :lens) do
      def fingerprint
        Canonical.digest(questions: questions.transform_values { |question| Lenses.fingerprint(question) }, reused: reused.sort)
      end

      def question_types
        questions.transform_values { |question| question["type"] }
      end
    end
  end
end
