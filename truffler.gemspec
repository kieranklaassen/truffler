require_relative "lib/truffler/version"

Gem::Specification.new do |spec|
  spec.name = "truffler"
  spec.version = Truffler::VERSION
  spec.authors = [ "Kieran Klaassen" ]
  spec.email = [ "kieranklaassen@gmail.com" ]

  spec.summary = "Intent search for Rails: Jev labels, query understanding, and reranking over your own database"
  spec.description = "Labels records with TypeSafe Jev when they are saved, stores the answers as numbers your " \
    "database filters and sorts, turns queries into label filters and boosts, and streams a Jev rerank on " \
    "explicit action."
  spec.homepage = "https://github.com/kieranklaassen/truffler"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md", "bench/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activejob", ">= 7.2", "< 9"
  spec.add_dependency "activerecord", ">= 7.2", "< 9"
  spec.add_dependency "activesupport", ">= 7.2", "< 9"
  spec.add_dependency "zeitwerk", "~> 2.6"
end
