module Truffler
  module Tokens
    CHARS_PER_TOKEN = 3

    module_function

    def estimate(value)
      text = value.is_a?(String) ? value : JSON.generate(value)
      (text.length / CHARS_PER_TOKEN.to_f).ceil
    end
  end
end
