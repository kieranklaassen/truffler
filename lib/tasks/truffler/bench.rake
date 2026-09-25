namespace :truffler do
  desc "Run the benchmark and print a JSON report. MODE=replay (default)|record|synthetic, PARAMS=path, " \
    "BENCH_RECORDS=n (generated synthetic dataset), JEV=synthetic|live, CASSETTES=dir, OUT=path"
  task :bench do
    require "truffler"
    require "json"

    Truffler::Benchmark::Database.connect!
    report = Truffler::Benchmark::Runner.from_env(ENV).run
    json = JSON.pretty_generate(report)
    File.write(ENV["OUT"], "#{json}\n") if ENV["OUT"].present?
    puts json
    abort "truffler:bench checks failed: #{report['checks']['failures'].join(', ')}" unless report["checks"]["passed"]
  end

  namespace :bench do
    desc "Regenerate the committed synthetic fixtures under bench/fixtures"
    task :fixtures do
      require "truffler"

      bench = Truffler::Benchmark
      bench::Generator.new(records: 90, tenants: 3, seed: bench::Generator::DEFAULT_SEED).dataset.write(bench.path("fixtures"))
    end
  end
end
