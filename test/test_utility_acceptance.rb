# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestUtilityAcceptance < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(ROOT, "exe", "branchproof")

  def test_minitest_policy_matrix_covers_pass_fail_exact_and_incomplete
    with_minitest_project do |root|
      full = run_cli(root, ["analyze", "lib/decision.rb", "--test", "test/decision_test.rb",
                            "--format", "json", "--minimum", "mcdc=100"])
      assert_equal 0, full.fetch(:status).exitstatus, full.fetch(:stderr)
      assert_equal "PASSED", full.dig(:json, "baseline", "status")
      assert_equal "passed", full.dig(:json, "coverage_policy", "status")
      assert_equal 100, full.dig(:json, "coverage_policy", "gates", 0, "minimum")
      assert_equal [2, 2], full.dig(:json, "coverage_policy", "gates", 0).values_at("numerator", "denominator")

      File.write(File.join(root, "test/decision_test.rb"), minitest_source(:partial))
      below = run_cli(root, ["analyze", "lib/decision.rb", "--test", "test/decision_test.rb",
                             "--format", "json", "--minimum", "mcdc=100.0"])
      assert_equal 1, below.fetch(:status).exitstatus, below.fetch(:stderr)
      assert_equal "PASSED", below.dig(:json, "baseline", "status")
      assert_equal "failed", below.dig(:json, "coverage_policy", "status")
      assert_equal 100.0, below.dig(:json, "coverage_policy", "gates", 0, "minimum")

      exact = run_cli(root, ["analyze", "lib/decision.rb", "--test", "test/decision_test.rb",
                             "--format", "json", "--minimum", "mcdc=0"])
      assert_equal 0, exact.fetch(:status).exitstatus, exact.fetch(:stderr)
      assert_equal "passed", exact.dig(:json, "coverage_policy", "status")

      File.write(File.join(root, "test/decision_test.rb"), "")
      incomplete = run_cli(root, ["analyze", "lib/decision.rb", "--test", "test/decision_test.rb",
                                  "--format", "json", "--minimum", "mcdc=0"])
      assert_equal 2, incomplete.fetch(:status).exitstatus, incomplete.fetch(:stderr)
      assert_equal "INCOMPLETE", incomplete.dig(:json, "baseline", "status")
      assert_equal "unavailable", incomplete.dig(:json, "coverage_policy", "status")
    end
  end

  def test_rspec_policy_matrix_reports_gate_status_and_incomplete_selection
    with_rspec_project do |root|
      full = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--test", "spec/access_spec.rb",
                            "--format", "json", "--minimum", "mcdc=100"])
      assert_equal 0, full.fetch(:status).exitstatus, full.fetch(:stderr)
      assert_equal "passed", full.dig(:json, "coverage_policy", "status")
      assert_equal [2, 2], full.dig(:json, "coverage_policy", "gates", 0).values_at("numerator", "denominator")

      File.write(File.join(root, "spec/access_spec.rb"), rspec_source(:partial))
      below = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--test", "spec/access_spec.rb",
                             "--format", "json", "--minimum", "mcdc=100"])
      assert_equal 1, below.fetch(:status).exitstatus, below.fetch(:stderr)
      assert_equal "failed", below.dig(:json, "coverage_policy", "status")

      empty = run_cli(root, ["analyze", "lib/decision.rb", "--framework", "rspec", "--test", "spec/missing_spec.rb",
                             "--format", "json", "--minimum", "mcdc=0"])
      assert_equal 2, empty.fetch(:status).exitstatus, empty.fetch(:stderr)
      assert_equal "unavailable", empty.dig(:json, "coverage_policy", "status")
    end
  end

  def test_configuration_and_cli_criterion_override_are_composed_in_a_real_run
    with_minitest_project do |root|
      File.write(File.join(root, ".branchproof.json"),
                 JSON.generate(schema_version: 1, minimum: { mcdc: 100, decision: 100 }))
      result = run_cli(root, ["analyze", "--format", "json", "--minimum", "mcdc=0"])

      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_equal({ "mcdc" => 0, "decision" => 100 }, result.dig(:json, "coverage_policy", "minimum"))
      assert_equal %w[mcdc decision].sort,
                   result.dig(:json, "coverage_policy", "gates").map { |gate| gate.fetch("criterion") }.sort
    end
  end

  def test_schema_14_report_requires_the_coverage_policy_section
    with_minitest_project do |root|
      result = run_cli(root, ["analyze", "--format", "json", "--output", "schema-14.json"])
      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      document = JSON.parse(File.read(File.join(root, "schema-14.json")))
      assert_equal "1.4", document.fetch("schema_version")
      document.delete("coverage_policy")
      File.write(File.join(root, "missing-policy.json"), JSON.generate(document))

      rejected = run_cli(root, ["report", "missing-policy.json"])
      assert_equal 2, rejected.fetch(:status).exitstatus
      assert_empty rejected.fetch(:stdout)
      assert_includes rejected.fetch(:stderr), "coverage_policy"
    end
  end

  def test_offline_report_survives_source_deletion_without_mutating_input_and_honors_saved_override
    with_minitest_project do |root|
      below = run_cli(root, ["analyze", "--format", "json", "--minimum", "mcdc=100", "--minimum", "decision=0",
                             "--output", "saved.json"],
                      source: minitest_source(:partial))
      assert_equal 1, below.fetch(:status).exitstatus, below.fetch(:stderr)
      report_path = File.join(root, "saved.json")
      original = File.binread(report_path)
      digest = Digest::SHA256.hexdigest(original)
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))
      File.write(File.join(root, ".branchproof.json"), "not JSON")

      inherited = run_cli(root, ["report", "saved.json", "--format", "json"])
      assert_equal 1, inherited.fetch(:status).exitstatus, inherited.fetch(:stderr)
      assert_equal "failed", inherited.dig(:json, "coverage_policy", "status")
      overridden = run_cli(root, ["report", "saved.json", "--format", "json", "--minimum", "mcdc=0"])
      assert_equal 0, overridden.fetch(:status).exitstatus, overridden.fetch(:stderr)
      assert_equal 0, overridden.dig(:json, "coverage_policy", "minimum", "mcdc")
      assert_equal 0, overridden.dig(:json, "coverage_policy", "minimum", "decision")
      assert_equal digest, Digest::SHA256.hexdigest(File.binread(report_path))
      assert_equal original, File.binread(report_path)
    end
  end

  def test_legacy_schema_reports_reload_with_optional_policy_overlay
    with_minitest_project do |root|
      result = run_cli(root, ["analyze", "--format", "json", "--output", "saved.json"])
      assert_equal 0, result.fetch(:status).exitstatus, result.fetch(:stderr)
      source = JSON.parse(File.read(File.join(root, "saved.json")))
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))

      %w[1.0 1.1 1.2 1.3].each do |schema|
        document = Marshal.load(Marshal.dump(source))
        document["schema_version"] = schema
        document.delete("coverage_policy")
        if schema < "1.3"
          document.fetch("analysis").fetch("decisions").each { |decision| decision.delete("decision_table") }
        end
        path = File.join(root, "legacy-#{schema}.json")
        File.write(path, JSON.generate(document))
        overlay_path = File.join(root, "legacy-#{schema}-overlay.json")
        report = run_cli(root, ["report", path, "--format", "json", "--minimum", "mcdc=0",
                                "--output", overlay_path])

        assert_equal 0, report.fetch(:status).exitstatus, "#{schema}: #{report.fetch(:stderr)}"
        assert_equal schema, JSON.parse(File.read(overlay_path)).fetch("schema_version")
        assert_equal 0, JSON.parse(File.read(overlay_path)).dig("coverage_policy", "minimum", "mcdc")
        reloaded = run_cli(root, ["report", overlay_path, "--format", "json"])
        assert_equal 0, reloaded.fetch(:status).exitstatus, "#{schema} overlay: #{reloaded.fetch(:stderr)}"
        assert_equal schema, reloaded.dig(:json, "schema_version")
        assert_equal 0, reloaded.dig(:json, "coverage_policy", "minimum", "mcdc")
      end
    end
  end

  private

  def with_minitest_project
    Dir.mktmpdir("branchproof-utility-minitest-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib/decision.rb"), <<~RUBY)
        def decide(left, right)
          if left && right
            :yes
          else
            :no
          end
        end
      RUBY
      File.write(File.join(root, "test/decision_test.rb"), minitest_source(:full))
      yield root
    end
  end

  def with_rspec_project
    Dir.mktmpdir("branchproof-utility-rspec-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "spec"))
      File.write(File.join(root, "lib/decision.rb"), <<~RUBY)
        def decide(left, right)
          if left && right
            :yes
          else
            :no
          end
        end
      RUBY
      File.write(File.join(root, "spec/spec_helper.rb"), "require \"rspec/expectations\"\n")
      File.write(File.join(root, ".rspec"), "--require spec_helper\n--format progress\n")
      File.write(File.join(root, "spec/access_spec.rb"), rspec_source(:full))
      yield root
    end
  end

  def minitest_source(kind, marker: nil)
    calls = case kind
            when :partial then "assert_equal :yes, decide(true, true)"
            when :marked then "File.write(#{marker.inspect}, \"ran\")\n            assert_equal :yes, decide(true, true)"
            else <<~RUBY
              assert_equal :yes, decide(true, true)
              assert_equal :no, decide(true, false)
              assert_equal :no, decide(false, true)
            RUBY
            end
    <<~RUBY
      require "minitest/autorun"
      require_relative "../lib/decision"
      class DecisionTest < Minitest::Test
        def test_decision
          #{calls}
        end
      end
    RUBY
  end

  def rspec_source(kind)
    calls = if kind == :partial
              "expect(decide(true, true)).to eq(:yes)"
            else
              <<~RUBY
                expect(decide(true, true)).to eq(:yes)
                expect(decide(true, false)).to eq(:no)
                expect(decide(false, true)).to eq(:no)
              RUBY
            end
    <<~RUBY
      require "decision"
      RSpec.describe "Decision" do
        it("covers decision") do
          #{calls}
        end
      end
    RUBY
  end

  def run_cli(root, args, source: nil)
    File.write(File.join(root, "test/decision_test.rb"), source) if source
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *args, chdir: root)
    output_path = args.include?("--output") ? args[args.index("--output") + 1] : nil
    has_json = output_path ? File.file?(File.join(root, output_path)) : !stdout.empty?
    json = if has_json && (args.first == "analyze" || (args.first == "report" && args.include?("--format") && args.include?("json")))
             payload = output_path ? File.read(File.join(root, output_path)) : stdout
             JSON.parse(payload)
           end
    { stdout: stdout, stderr: stderr, status: status, json: json }
  rescue JSON::ParserError => e
    flunk "expected JSON output: #{e.message}; stdout=#{stdout.inspect}; stderr=#{stderr.inspect}"
  end
end
