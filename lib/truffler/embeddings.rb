module Truffler
  # Optional text embeddings (R10, R11) and the label vectors of KTD20. The
  # embedding text is built from the declared fields inside the embed step
  # only and is never stored.
  module Embeddings
    module_function

    def embedder
      Truffler.config.embedder || RubyLLMEmbedder.new
    end

    # Gem-managed embeddings, as opposed to a host column the gem only reads.
    def managed?(definition)
      definition.embeddings.present? && !definition.embeddings.key?(:column)
    end

    # Changes when the embedding model, the width, or the embedded fields
    # change, which marks every stored vector stale.
    def fingerprint(definition)
      settings = definition.embeddings
      Canonical.digest(model: settings[:model], dimensions: settings[:dimensions], fields: definition.fields)
    end

    def text_for(definition, record, max_chars: Truffler.config.max_field_chars)
      definition.field_values(record).filter_map do |field, value|
        "#{field}: #{value.to_s.truncate(max_chars, omission: '')}" if value.present?
      end.join("\n")
    end
  end
end
