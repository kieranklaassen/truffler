module Truffler
  Usage = Data.define(:input_tokens, :estimated) do
    def cost
      Truffler.config.cost_for(input_tokens)
    end
  end
end
