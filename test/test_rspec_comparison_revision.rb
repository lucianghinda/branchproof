# frozen_string_literal: true

require "test_helper"
require "branchproof/comparison"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestRSpecComparisonRevision < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/branchproof", __dir__)

  def test_saved_reports_reject_positional_matches_after_insertion_and_reordering
    with_project do |root|
      spec = File.join(root, "spec", "decision_spec.rb")
      File.write(spec, examples([true, false]))
      before = saved_report(root, "before")
      unchanged = saved_report(root, "unchanged")
      owners = comparison(before, unchanged).fetch("changes").flat_map { |change| change.fetch("owner_context") }
      refute_empty owners
      assert(owners.all? { |owner| owner.fetch("test_status") == "present in current run" })

      [[true, true, false], [false, true]].each_with_index do |values, index|
        File.write(spec, examples(values))
        after = saved_report(root, "after-#{index}")
        assert_equal Digest::SHA256.file(spec).hexdigest, after.dig("observations", "tests", 0, "spec_digest")
        assert_unmatched(before, after)
      end
    end
  end

  def test_saved_reports_reject_duplicate_shared_examples_when_only_the_definition_changes
    with_project do |root|
      shared = File.join(root, "spec", "shared.rb")
      File.write(shared, shared_examples([true, false]))
      File.write(File.join(root, "spec", "decision_spec.rb"), <<~RUBY)
        require "spec_helper"
        require_relative "shared"
        RSpec.describe("Decision") { include_examples "values" }
      RUBY
      before = saved_report(root, "before")
      File.write(shared, shared_examples([false, true]))
      after = saved_report(root, "after")

      before_test = before.dig("observations", "tests", 0)
      after_test = after.dig("observations", "tests", 0)
      assert_equal before_test.fetch("spec_digest"), after_test.fetch("spec_digest")
      refute_equal before_test.fetch("source_digest"), after_test.fetch("source_digest")
      assert_equal Digest::SHA256.file(shared).hexdigest, after_test.fetch("source_digest")
      assert_unmatched(before, after)
    end
  end

  private

  def with_project
    Dir.mktmpdir("branchproof-rspec-comparison-") do |root|
      %w[lib spec].each { |directory| FileUtils.mkdir_p(File.join(root, directory)) }
      File.write(File.join(root, "lib", "decision.rb"), <<~RUBY)
        def branchproof_decision(value)
          if value
            :yes
          else
            :no
          end
        end
      RUBY
      File.write(File.join(root, "spec", "spec_helper.rb"), "require 'rspec/expectations'\nrequire 'decision'\n")
      yield root
    end
  end

  def examples(values)
    "require 'spec_helper'\nRSpec.describe 'Decision' do\n#{example_bodies(values)}end\n"
  end

  def shared_examples(values)
    "RSpec.shared_examples 'values' do\n#{example_bodies(values)}end\n"
  end

  def example_bodies(values)
    values.map { |value| "  it('same description') { expect(branchproof_decision(#{value})).to eq(#{value ? ":yes" : ":no"}) }\n" }.join
  end

  def saved_report(root, name)
    path = File.join(root, "#{name}.json")
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE,
                                            "analyze", "lib/decision.rb", "--framework", "rspec",
                                            "--test", "spec/decision_spec.rb", "--format", "json", "--output", path,
                                            chdir: root)
    assert status.success?, "#{stdout}\n#{stderr}\n#{File.read(path) if File.file?(path)}"
    JSON.parse(File.read(path))
  end

  def comparison(before, after)
    Branchproof::Comparison.new(before: before, after: after).call
  end

  def assert_unmatched(before, after)
    result = comparison(before, after)
    owners = result.fetch("changes").flat_map { |change| change.fetch("owner_context") }
    refute_empty owners
    assert(owners.all? { |owner| owner.fetch("test_status").include?("no unique test match") })
    assert_includes result.fetch("context"), "test population differs"
  end
end
