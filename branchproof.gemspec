# frozen_string_literal: true

require_relative "lib/branchproof/version"

Gem::Specification.new do |spec|
  spec.name = "branchproof"
  spec.version = Branchproof::VERSION
  spec.authors = ["Lucian Ghinda"]
  spec.email = ["lucianghinda@users.noreply.github.com"]

  spec.summary = "Modified condition and decision coverage for Ruby tests"
  spec.description = "Inventory Ruby decisions and report masking MC/DC evidence from Minitest runs."
  spec.homepage = "https://github.com/lucianghinda/branchproof"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["CHANGELOG.md", "CODE_OF_CONDUCT.md", "LICENSE*", "NOTICE", "README.md", "exe/*", "lib/**/*.rb",
        "sig/**/*.rbs", "doc/**/*.md", "llms.txt"].select { |path| File.file?(path) }.sort
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "minitest", ">= 5.25.5", "< 6"
  spec.add_dependency "prism", ">= 1.0", "< 2"
end
