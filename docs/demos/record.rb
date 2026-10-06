# frozen_string_literal: true

require "fileutils"

root = File.expand_path("../..", __dir__)
workspace = File.join(root, "tmp/demos")
FileUtils.mkdir_p(workspace)
%w[access.rb access_test.rb suspension_test.rb].each do |name|
  FileUtils.cp(File.join(__dir__, name), workspace)
end

# Use the checkout's bundle even after the tape changes into its sample project.
environment = { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }
%w[mcdc decision-table].each do |name|
  abort "Recording failed: #{name}" unless system(environment, "vhs", "docs/demos/#{name}.tape", chdir: root)
end
