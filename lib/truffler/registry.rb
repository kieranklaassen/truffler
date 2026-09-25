module Truffler
  # Declared models by class name, so code reloading never pins stale classes.
  class Registry
    def initialize
      @names = Set.new
    end

    def register(model)
      @names << model.name
    end

    def models
      @names.filter_map(&:safe_constantize)
    end
  end
end
