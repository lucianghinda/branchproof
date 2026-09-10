# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/test_*.rb"]
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]
