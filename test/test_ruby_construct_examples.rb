# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class TestRubyConstructExamples < Minitest::Test
  ROOT = File.expand_path("fixtures/ruby_constructs", __dir__)
  COUNTS = { "VAL" => 7, "IF" => 9, "LOG" => 10, "CASE" => 8, "PAT" => 24,
             "NIL" => 7, "ASGN" => 8, "ARG" => 5, "LOOP" => 9, "FLIP" => 2,
             "EXC" => 14, "FLOW" => 12, "PRED" => 17, "API" => 10 }.freeze
  ENTRIES = Dir[File.join(ROOT, "*.json")].flat_map { |file| JSON.parse(File.read(file)) }.freeze
  RUNNER = <<~RUBY
    require "json"
    require "timeout"

    load ARGV.fetch(0)
    inputs = JSON.parse(ARGV.fetch(1))
    begin
      result = Timeout.timeout(5) do
        example(*inputs.fetch("args", []), **inputs.fetch("kwargs", {}).transform_keys(&:to_sym))
      end
      puts JSON.generate("result" => result)
    rescue StandardError => error
      puts JSON.generate("error" => error.class.name)
    end
  RUBY

  def test_every_catalog_entry_has_a_source_file_and_cases
    expected_ids = COUNTS.flat_map do |family, count|
      (1..count).map { |number| format("%<family>s-%<number>02d", family: family, number: number) }
    end
    assert_equal expected_ids.sort, ENTRIES.map { |entry| entry.fetch("id") }.sort
    expected_files = expected_ids.map { |id| "#{id.downcase.tr("-", "_")}.rb" }
    assert_equal expected_files.sort, Dir[File.join(ROOT, "*.rb")].map { |path| File.basename(path) }.sort

    ENTRIES.each do |entry|
      refute_empty entry.fetch("cases"), entry.fetch("id")
      entry.fetch("cases").each do |sample|
        assert_equal 1, (sample.keys & %w[result error exit]).size, sample.inspect
        assert_kind_of String, sample.fetch("name")
      end
    end
  end

  ENTRIES.each do |entry|
    id = entry.fetch("id")
    path = File.join(ROOT, "#{id.downcase.tr("-", "_")}.rb")

    define_method("test_#{id}_valid_ruby") do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", path)
      assert status.success?, "#{id}: #{stdout}\n#{stderr}"
    end

    entry.fetch("cases").each_with_index do |sample, index|
      define_method("test_#{id}_#{index}_#{sample.fetch("name")}") do
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", RUNNER, path, JSON.generate(sample))
        message = "#{id} / #{sample.fetch("name")}: #{stderr}\n#{stdout}"
        if sample.key?("exit")
          assert_equal sample.fetch("exit"), status.exitstatus, message
          assert_equal sample.fetch("stdout", ""), stdout, message
          assert_equal sample.fetch("stderr", ""), stderr, message
        else
          assert status.success?, message
          expected = sample.slice("result", "error")
          assert_equal expected, JSON.parse(stdout), message
        end
      end
    end
  end
end
