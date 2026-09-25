namespace :truffler do
  task :setup do
    Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
  end

  resolve_model = lambda do |name|
    model = name.to_s.safe_constantize
    abort "#{name} is not a Truffler model" unless model.respond_to?(:truffler_definition) && model.truffler_definition
    model
  end

  resolve_spend_cap = lambda do |value|
    case value.to_s.strip.downcase
    when "" then Truffler.config.backfill_spend_cap
    when "none" then nil
    else Float(value, exception: false) || abort("SPEND_CAP must be a dollar amount or none, got #{value.inspect}")
    end
  end

  resolve_max_duration = lambda do |value|
    next if value.to_s.strip.empty?

    seconds = Float(value, exception: false)
    abort "MAX_DURATION must be a number of seconds, got #{value.inspect}" unless seconds&.positive?
    seconds
  end

  describe_cursor = ->(cursor) { cursor.nil? ? "none" : cursor }

  desc "Backfill stale, missing, and failed labels for a model, waiting out budget denials " \
    "(SPEND_CAP=dollars or none; default config.backfill_spend_cap; MAX_DURATION=seconds; RESET_SPEND=1 for a fresh spend ledger)"
  task :backfill, [ :model ] => :setup do |_, args|
    model = resolve_model.call(args[:model])
    spend_cap = resolve_spend_cap.call(ENV.fetch("SPEND_CAP", nil))
    max_duration = resolve_max_duration.call(ENV.fetch("MAX_DURATION", nil))
    if ENV.fetch("RESET_SPEND", nil) == "1"
      Truffler::Labeling::Backfill.reset_spend!(model)
      puts "#{model.name}: fresh spend ledger for the current vocabulary version"
    end
    progress = lambda do |so_far, delay|
      puts "#{model.name}: waiting #{format('%.1f', delay)}s for backfill budget (#{so_far.labeled} labeled, " \
        "$#{format('%.6f', so_far.cost)} spent, cursor #{describe_cursor.call(so_far.cursor)})"
    end
    result = Truffler::Labeling::Backfill.new(model, spend_cap: spend_cap).run(wait: true, max_duration: max_duration, progress: progress)
    summary = "#{model.name}: #{result.status}, #{result.labeled} labeled in #{result.requests} requests, $#{format('%.6f', result.cost)}"
    summary += ", cursor #{describe_cursor.call(result.cursor)}" if result.status == :paused
    puts summary
  end

  desc "Print a model's labeling counts by status and staleness"
  task :status, [ :model ] => :setup do |_, args|
    model = resolve_model.call(args[:model])
    puts model.name
    Truffler::Labeling::Backfill.status(model).each { |key, count| puts format("  %-9s %d", key, count) }
    if Truffler::Records::BackfillSpend.available?
      ledger = Truffler::Labeling::Backfill.spend(model)
      cap = Truffler.config.backfill_spend_cap
      puts format("  %-9s $%.6f in %d requests (vocabulary %s, cap %s)", "spent", ledger&.spent_usd.to_f, ledger&.requests.to_i,
        Truffler::Labeling::Backfill.ledger_version(model).first(12), cap ? format("$%.2f", cap) : "none")
    else
      puts format("  %-9s %s", "spent", "not tracked across runs; run bin/rails g truffler:upgrade && bin/rails db:migrate")
    end
  end
end
