# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "minitest/test_task"
require "rbconfig"
require "yard"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/test_*.rb"]
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

YARD::Rake::YardocTask.new do |task|
  task.before = -> { FileUtils.rm_rf(File.join(File.expand_path(__dir__), "doc")) }
end

desc "Generate Markdown API documentation and the LLM index"
task docs: :yard do
  sh RbConfig.ruby, File.join(File.expand_path(__dir__), "bin/generate_llm.rb")
end

task default: %i[test rubocop]
