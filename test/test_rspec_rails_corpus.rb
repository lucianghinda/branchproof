# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/rspec_constructs"

class TestRSpecRailsCorpus < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rspec_rails_app", __dir__).freeze

  def test_native_and_instrumented_rails_runs_cover_the_full_rspec_corpus
    unless ENV["BRANCHPROOF_RSPEC_RAILS_INTEGRATION"] == "1"
      skip "set BRANCHPROOF_RSPEC_RAILS_INTEGRATION=1 to run the Rails/RSpec corpus"
    end

    reports = []
    [false, true].each do |eager|
      Dir.mktmpdir("branchproof-rspec-rails-corpus-") do |root|
        copy_fixture(root)
        RSpecConstructs.write_project(root)
        prepend_rails_helper(root)
        env = {
          "RAILS_ENV" => "test",
          "BRANCHPROOF_RSPEC_FIXTURE_DB" => File.join(root, "tmp", "test.sqlite3"),
          "BRANCHPROOF_FIXTURE_EAGER" => eager ? "1" : "0"
        }
        native_stdout, native_stderr, native_status = Open3.capture3(
          env, "bundle", "exec", "rspec", "--format", "progress", "spec/corpus_spec.rb", chdir: root
        )
        assert native_status.success?, "native Rails RSpec failed (eager=#{eager}): #{native_stdout}\n#{native_stderr}"
        assert_match(/403 examples, 0 failures/, native_stdout)

        cli_stdout, cli_stderr, cli_status = Open3.capture3(
          env, RbConfig.ruby, RSpecConstructs::EXECUTABLE, "analyze", "lib/corpus/**/*.rb",
          "--project", "rails", "--framework", "rspec", "--format", "json",
          "--level", "1", "--test", "spec/corpus_spec.rb", chdir: root
        )
        report = JSON.parse(cli_stdout)
        assert cli_status.success?, cli_stderr
        assert_equal "PASSED", report.dig("baseline", "status"), cli_stderr
        assert_equal 403, report.dig("baseline", "executed_tests")
        assert_equal "rails", report.dig("baseline", "project", "kind")
        refute_match(/Minitest/, cli_stderr)
        assert_equal 285, report.dig("metrics", "discovered")
        reports << report
        assert_rails_termination_cases(root, env)
      end
    end
    assert_equal 2, reports.length
    reports.map! do |report|
      inventory = report.fetch("source_inventory")
      decisions = inventory.fetch("decisions").map do |decision|
        decision.values_at("context", "byte_start", "byte_length")
      end.sort_by(&:inspect)
      vectors = report.fetch("observations").fetch("vectors").map do |vector|
        vector.values_at("decision_id", "values", "outcome")
      end.sort_by(&:inspect)
      [decisions, vectors]
    end
    assert_equal reports.first, reports.last, "lazy and eager Rails corpus observations diverged"
  end

  private

  def copy_fixture(root)
    FileUtils.cp_r(Dir[File.join(FIXTURE, "*")], root)
  end

  def prepend_rails_helper(root)
    path = File.join(root, "spec", "corpus_spec.rb")
    File.write(path, "require \"rails_helper\"\n#{File.read(path)}")
  end

  def assert_rails_termination_cases(root, env)
    flow_path = File.join(root, "lib", "corpus", "flow_12.rb")
    RSpecConstructs.entries.find { |entry| entry.fetch("id") == "FLOW-12" }.fetch("cases").each do |sample|
      args = sample.fetch("args").inspect
      File.write(File.join(root, "spec", "corpus_spec.rb"), <<~RUBY)
        require "rails_helper"
        RSpec.describe "FLOW-12 #{sample.fetch("name")}" do
          it("terminates") do
            scope = Module.new
            load(#{flow_path.inspect}, scope)
            Object.new.extend(scope).send(:example, *#{args})
          end
        end
      RUBY
      native_stdout, native_stderr, native_status = Open3.capture3(
        env, "bundle", "exec", "rspec", "--format", "progress", "spec/corpus_spec.rb", chdir: root
      )
      assert_equal sample.fetch("exit"), native_status.exitstatus,
                   "native Rails termination mismatch for #{sample.fetch("name")}: #{native_stdout}\n#{native_stderr}"

      cli_stdout, cli_stderr, cli_status = Open3.capture3(
        env, RbConfig.ruby, RSpecConstructs::EXECUTABLE, "analyze", "lib/corpus/**/*.rb",
        "--project", "rails", "--framework", "rspec", "--format", "json", "--level", "1",
        "--test", "spec/corpus_spec.rb", chdir: root
      )
      assert_equal 2, cli_status.exitstatus, "CLI termination unexpectedly succeeded: #{cli_stdout}\n#{cli_stderr}"
      report = JSON.parse(cli_stdout)
      assert_includes %w[ERROR INCOMPLETE], report.dig("baseline", "status")
      refute_equal true, report.dig("baseline", "finalized")
    end
  end
end
