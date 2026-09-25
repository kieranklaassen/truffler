namespace :truffler do
  task :setup do
    Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
  end

  resolve_model = lambda do |name|
    model = name.to_s.safe_constantize
    abort "#{name} is not a Truffler model" unless model.respond_to?(:truffler_definition) && model.truffler_definition
    model
  end

  desc "Backfill stale, missing, and failed labels for a model (SPEND_CAP=dollars)"
  task :backfill, [ :model ] => :setup do |_, args|
    model = resolve_model.call(args[:model])
    spend_cap = ENV["SPEND_CAP"].presence&.to_f || Truffler.config.backfill_spend_cap
    result = Truffler::Labeling::Backfill.new(model, spend_cap: spend_cap).run
    puts "#{model.name}: #{result.status}, #{result.labeled} labeled in #{result.requests} requests, $#{format('%.6f', result.cost)}"
  end

  desc "Print a model's labeling counts by status and staleness"
  task :status, [ :model ] => :setup do |_, args|
    model = resolve_model.call(args[:model])
    puts model.name
    Truffler::Labeling::Backfill.status(model).each { |key, count| puts format("  %-9s %d", key, count) }
  end
end
