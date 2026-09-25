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

  resolve_tenant = ->(value) { value.to_s.strip.presence }

  describe_model = ->(model, tenant_key) { tenant_key ? "#{model.name} (tenant #{tenant_key})" : model.name }

  desc "Backfill stale, missing, and failed labels for a model, waiting out budget denials " \
    "(TENANT=key for one tenant; SPEND_CAP=dollars or none; default config.backfill_spend_cap; MAX_DURATION=seconds; " \
    "RESET_SPEND=1 for a fresh spend ledger)"
  task :backfill, [ :model ] => :setup do |_, args|
    model = resolve_model.call(args[:model])
    tenant_key = resolve_tenant.call(ENV.fetch("TENANT", nil))
    name = describe_model.call(model, tenant_key)
    spend_cap = resolve_spend_cap.call(ENV.fetch("SPEND_CAP", nil))
    max_duration = resolve_max_duration.call(ENV.fetch("MAX_DURATION", nil))
    if ENV.fetch("RESET_SPEND", nil) == "1"
      ledger_tenant = model.truffler_definition.ledger_tenant(tenant_key)
      all_tenants = ledger_tenant.nil? && !model.truffler_definition.ledger_tenant("").nil?
      Truffler::Labeling::Backfill.reset_spend!(model, tenant_key: ledger_tenant, all_tenants: all_tenants)
      puts all_tenants ? "#{name}: fresh spend ledgers for every tenant" : "#{name}: fresh spend ledger for the current vocabulary version"
    end
    progress = lambda do |so_far, delay|
      puts "#{name}: waiting #{format('%.1f', delay)}s for backfill budget (#{so_far.labeled} labeled, " \
        "$#{format('%.6f', so_far.cost)} spent, cursor #{describe_cursor.call(so_far.cursor)})"
    end
    result = Truffler::Labeling::Backfill.new(model, tenant_key: tenant_key, spend_cap: spend_cap)
      .run(wait: true, max_duration: max_duration, progress: progress)
    summary = "#{name}: #{result.status}, #{result.labeled} labeled in #{result.requests} requests, $#{format('%.6f', result.cost)}"
    summary += ", cursor #{describe_cursor.call(result.cursor)}" if result.status == :paused
    puts summary
  end

  print_status = lambda do |model, tenant_key = nil|
    puts describe_model.call(model, tenant_key)
    Truffler::Labeling::Backfill.status(model).each { |key, count| puts format("  %-9s %d", key, count) }
    ledger_tenant = model.truffler_definition.ledger_tenant(tenant_key)
    if Truffler::Records::BackfillSpend.available? && Truffler::Records::BackfillSpend.tenant_ledgers? &&
        model.truffler_definition.ledger_tenant("") && ledger_tenant.nil?
      puts format("  %-9s %s", "spent", "per tenant; pass TENANT=key")
    elsif Truffler::Records::BackfillSpend.available?
      ledger = Truffler::Labeling::Backfill.spend(model, tenant_key: ledger_tenant)
      cap = Truffler.config.backfill_spend_cap
      puts format("  %-9s $%.6f in %d requests (vocabulary %s, cap %s)", "spent", ledger&.spent_usd.to_f, ledger&.requests.to_i,
        Truffler::Labeling::Backfill.ledger_version(model, ledger_tenant).first(12), cap ? format("$%.2f", cap) : "none")
    else
      puts format("  %-9s %s", "spent", "not tracked across runs; run bin/rails g truffler:upgrade && bin/rails db:migrate")
    end
  end

  desc "Print a model's labeling counts by status and staleness (every registered Truffler model when none is named; " \
    "TENANT=key for a tenant's spend ledger)"
  task :status, [ :model ] => :setup do |_, args|
    if args[:model].to_s.strip.empty?
      Rails.application.eager_load! if defined?(Rails.application) && Rails.application
      models = Truffler.registry.models.select { |model| model.try(:truffler_definition) }.sort_by(&:name)
      abort "No Truffler models are registered" if models.empty?
      models.each(&print_status)
    else
      print_status.call(resolve_model.call(args[:model]), resolve_tenant.call(ENV.fetch("TENANT", nil)))
    end
  end
end
