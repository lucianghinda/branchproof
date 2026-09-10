# frozen_string_literal: true

require "rails/test_help"

counter = Rails.root.join("tmp", "test_helper_loads")
FileUtils.mkdir_p(counter.dirname)
File.open(counter, "a") { |file| file.puts(Process.pid) }

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
  end
end
