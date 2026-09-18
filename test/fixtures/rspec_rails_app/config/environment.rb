# frozen_string_literal: true

require_relative "boot"
require_relative "application"
require "fileutils"

Rails.application.initialize!

counter = Rails.root.join("tmp", "environment_loads")
FileUtils.mkdir_p(counter.dirname)
File.open(counter, "a") { |file| file.puts(Process.pid) }

ActiveRecord::Schema.define do
  unless ActiveRecord::Base.connection.data_source_exists?("fixture_records")
    create_table :fixture_records, force: false do |table|
      table.string :name, null: false
      table.boolean :enabled, null: false, default: true
    end
  end
end
