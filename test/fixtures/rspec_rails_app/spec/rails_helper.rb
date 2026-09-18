# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require "fileutils"
require_relative "../config/environment"
require "rspec/rails"

counter = Rails.root.join("tmp", "rails_helper_loads")
FileUtils.mkdir_p(counter.dirname)
File.open(counter, "a") { |file| file.puts(Process.pid) }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.order = :defined
end
