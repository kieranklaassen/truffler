namespace :truffler do
  desc "Print candidate label questions from logged query misses, e.g. rake truffler:suggestions[Email]"
  task :suggestions, [ :model ] => :environment do |_, args|
    abort "usage: rake truffler:suggestions[ModelName]" if args[:model].blank?

    Truffler::Misses::Suggestions.report(args[:model])
  end
end
