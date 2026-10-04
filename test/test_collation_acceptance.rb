# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class TestCollationAcceptance < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/branchproof", __dir__)

  def test_minitest_shards_recompute_cross_shard_mcdc_offline
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      paid = analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      suspended = analyze(root, "test/suspended_test.rb", output: "artifacts/suspended.json")
      full = analyze(root, "test/paid_test.rb", "test/suspended_test.rb")
      [paid, suspended, full].each { assert_equal 0, _1[:status].exitstatus, _1[:stderr] }
      assert_equal 0, paid[:json].dig("analysis", "coverage", "mcdc", "proven_conditions")

      write_manifest(root, %w[paid suspended])
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "test"))
      result = run_cli(root, ["collate", "artifacts/paid.json", "artifacts/suspended.json", "--manifest",
                              "shards.json", "--output", "combined.json"])
      combined = JSON.parse(File.read(File.join(root, "combined.json")))

      assert_equal 0, result[:status].exitstatus, result[:stderr]
      assert_equal "complete", combined.dig("collation", "collection_status")
      assert_equal 2, combined.dig("baseline", "executed_tests")
      assert_equal full.dig(:json, "analysis", "coverage"), combined.dig("analysis", "coverage")
      assert_equal(full.dig(:json, "observations", "vectors").sort_by { _1.fetch("id") },
                   combined.dig("observations", "vectors").sort_by { _1.fetch("id") })
      assert_equal full.dig(:json, "observations", "tests").map { _1["id"] }.sort,
                   combined.dig("observations", "tests").map { _1["id"] }.sort

      rerendered = run_cli(root, ["report", "combined.json", "--format", "json", "--output", "rerendered.json"])
      assert_equal 0, rerendered[:status].exitstatus, rerendered[:stderr]
      rerendered_document = JSON.parse(File.read(File.join(root, "rerendered.json")))
      assert_equal "1.7", rerendered_document.fetch("schema_version")
      assert_equal combined.fetch("collation"), rerendered_document.fetch("collation")

      html = run_cli(root, ["report", "combined.json", "--format", "html", "--output", "combined.html"])
      assert_equal 0, html[:status].exitstatus, html[:stderr]
      assert_includes File.read(File.join(root, "combined.html")), "Collation: complete"
      comparison = run_cli(root, ["compare", "combined.json", "combined.json", "--format", "json"])
      assert_equal 0, comparison[:status].exitstatus, comparison[:stderr]
    end
  end

  def test_rspec_shards_collate_after_project_files_are_removed
    with_project do |root|
      write_boolean_project(root, framework: :rspec)
      paid = analyze(root, "spec/paid_spec.rb", framework: "rspec", output: "artifacts/paid.json")
      suspended = analyze(root, "spec/suspended_spec.rb", framework: "rspec", output: "artifacts/suspended.json")
      full = analyze(root, "spec/paid_spec.rb", "spec/suspended_spec.rb", framework: "rspec")
      [paid, suspended, full].each { assert_equal 0, _1[:status].exitstatus, _1[:stderr] }
      write_manifest(root, %w[paid suspended])
      FileUtils.rm_rf(File.join(root, "lib"))
      FileUtils.rm_rf(File.join(root, "spec"))
      FileUtils.rm_f(File.join(root, ".rspec"))

      result = run_cli(root, ["collate", "artifacts/paid.json", "artifacts/suspended.json", "--manifest", "shards.json"])
      combined = begin
        JSON.parse(result[:stdout])
      rescue JSON::ParserError
        flunk("collate produced no JSON: #{result[:stderr]}")
      end
      assert_equal 0, result[:status].exitstatus, result[:stderr]
      assert_equal "complete", combined.dig("collation", "collection_status")
      assert_equal full.dig(:json, "analysis", "coverage"), combined.dig("analysis", "coverage")
      assert_equal(full.dig(:json, "observations", "vectors").sort_by { _1.fetch("id") },
                   combined.dig("observations", "vectors").sort_by { _1.fetch("id") })
      assert_equal 2, combined.dig("baseline", "executed_tests")
    end
  end

  def test_default_json_without_manifest_is_unknown_and_incomplete
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      result = analyze(root, "test/paid_test.rb", output: "paid.json")
      assert_equal 0, result[:status].exitstatus, result[:stderr]

      collated = run_cli(root, ["collate", "paid.json"])
      document = JSON.parse(collated[:stdout])
      assert_equal 2, collated[:status].exitstatus
      assert_equal "unknown", document.dig("collation", "collection_status")
      assert_equal "INCOMPLETE", document.dig("baseline", "status")
      assert_equal false, document.dig("completeness", "observation")
    end
  end

  def test_missing_and_undeclared_manifest_inputs_exit_two
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      FileUtils.mkdir_p(File.join(root, "artifacts"))
      File.write(File.join(root, "shards.json"), JSON.generate(shards: [
                                                                 { id: "paid", report: "artifacts/paid.json" }, { id: "missing", report: "artifacts/missing.json" }
                                                               ]))
      File.write(File.join(root, "artifacts", "missing.json"), "malformed but omitted, so never read")

      missing = run_cli(root, ["collate", "artifacts/paid.json", "--manifest", "shards.json"])
      assert_equal 2, missing[:status].exitstatus
      assert_equal "incomplete", JSON.parse(missing[:stdout]).dig("collation", "collection_status")

      undeclared = run_cli(root, ["collate", "artifacts/paid.json", "--manifest", "shards.json", "extra.json"])
      assert_equal 2, undeclared[:status].exitstatus
      assert_includes undeclared[:stderr], "not declared"
    end
  end

  def test_duplicate_artifact_for_same_manifest_shard_is_idempotent
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      write_manifest(root, ["paid"])
      result = run_cli(root, ["collate", "artifacts/paid.json", "artifacts/paid.json", "--manifest", "shards.json"])
      assert_equal 0, result[:status].exitstatus, result[:stderr]
      document = JSON.parse(result[:stdout])
      assert_equal 1, document.fetch("collation").fetch("shards").length
      assert_equal 1, document.fetch("run_ids").length
      assert_equal 1, document.dig("baseline", "executed_tests")
    end
  end

  def test_repeated_test_id_across_distinct_runs_counts_executions_and_merges_phases
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/first.json")
      analyze(root, "test/paid_test.rb", output: "artifacts/second.json")
      File.write(File.join(root, "shards.json"), JSON.generate(shards: [
                                                                 { id: "first", report: "artifacts/first.json" }, { id: "second", report: "artifacts/second.json" }
                                                               ]))

      result = run_cli(root, ["collate", "artifacts/first.json", "artifacts/second.json", "--manifest", "shards.json"])
      document = JSON.parse(result[:stdout])
      assert_equal 0, result[:status].exitstatus, result[:stderr]
      assert_equal 2, document.dig("baseline", "executed_tests")
      tests = document.dig("observations", "tests")
      assert_equal 1, tests.length
      assert_equal 2, tests.first.dig("phase_counts", "body")
    end
  end

  def test_saved_changed_policy_override_keeps_collated_schema_and_provenance
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      git(root, "init", "-q")
      git(root, "config", "user.email", "branchproof@example.test")
      git(root, "config", "user.name", "Branchproof Test")
      git(root, "add", ".")
      git(root, "commit", "-qm", "baseline")
      source = File.join(root, "lib", "decision.rb")
      File.write(source, File.read(source).sub("paid && !suspended", "paid && !suspended && true"))
      raw = analyze(root, "test/paid_test.rb", output: "artifacts/changed.json",
                                               arguments: ["--changed-since", "HEAD", "--minimum-changed", "mcdc=0"])
      assert_equal 0, raw[:status].exitstatus, raw[:stderr]
      write_manifest(root, ["changed"])
      collated = run_cli(root, ["collate", "artifacts/changed.json", "--manifest", "shards.json",
                                "--output", "combined.json"])
      assert_equal 0, collated[:status].exitstatus, collated[:stderr]
      original = JSON.parse(File.read(File.join(root, "combined.json")))
      assert_equal "1.7", original.fetch("schema_version")

      override = run_cli(root, ["report", "combined.json", "--minimum-changed", "mcdc=100", "--format", "json",
                                "--output", "changed-policy.json"])
      assert_equal 1, override[:status].exitstatus, override[:stderr]
      changed = JSON.parse(File.read(File.join(root, "changed-policy.json")))
      assert_equal "1.7", changed.fetch("schema_version")
      assert_equal original.fetch("collation"), changed.fetch("collation")
      assert_equal({ "mcdc" => 100 }, changed.dig("changed_coverage_policy", "minimum_changed"))

      rerender = run_cli(root, ["report", "changed-policy.json", "--format", "json", "--output", "reloaded.json"])
      assert_equal 1, rerender[:status].exitstatus, rerender[:stderr]
      reloaded = JSON.parse(File.read(File.join(root, "reloaded.json")))
      assert_equal "1.7", reloaded.fetch("schema_version")
      assert_equal changed.fetch("collation"), reloaded.fetch("collation")
      assert_equal changed.fetch("changed_coverage_policy"), reloaded.fetch("changed_coverage_policy")
    end
  end

  def test_manifest_alias_to_missing_path_is_protected_through_symlinked_directory
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      FileUtils.mkdir_p(File.join(root, "artifacts"))
      Dir.mkdir(File.join(root, "real"))
      File.symlink(File.join(root, "real"), File.join(root, "linked"))
      File.write(File.join(root, "shards.json"), JSON.generate(shards: [
                                                                 { id: "paid", report: "artifacts/paid.json" }, { id: "missing", report: "linked/missing.json" }
                                                               ]))

      result = run_cli(root, ["collate", "artifacts/paid.json", "--manifest", "shards.json", "--output",
                              "real/missing.json"])
      assert_equal 2, result[:status].exitstatus
      assert_includes result[:stderr], "must not overwrite"
      refute File.exist?(File.join(root, "real", "missing.json"))
    end
  end

  def test_manifest_dangling_symlink_input_cannot_be_replaced_through_its_target
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      FileUtils.mkdir_p(File.join(root, "artifacts"))
      File.symlink("missing.json", File.join(root, "unit.json"))
      File.write(File.join(root, "shards.json"), JSON.generate(shards: [
                                                                 { id: "paid", report: "artifacts/paid.json" }, { id: "unit", report: "unit.json" }
                                                               ]))

      result = run_cli(root, ["collate", "artifacts/paid.json", "--manifest", "shards.json", "--output", "missing.json"])
      assert_equal 2, result[:status].exitstatus
      assert_includes result[:stderr], "must not overwrite"
      refute File.exist?(File.join(root, "missing.json"))
    end
  end

  def test_output_cannot_replace_supplied_manifest_or_omitted_artifacts_including_hardlinks
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      analyze(root, "test/paid_test.rb", output: "artifacts/paid.json")
      File.write(File.join(root, "artifacts", "omitted.json"), "omitted artifact")
      File.write(File.join(root, "shards.json"), JSON.generate(shards: [
                                                                 { id: "paid", report: "artifacts/paid.json" }, { id: "omitted", report: "artifacts/omitted.json" }
                                                               ]))
      File.link(File.join(root, "artifacts", "paid.json"), File.join(root, "hardlink.json"))
      protected = %w[artifacts/paid.json shards.json artifacts/omitted.json hardlink.json]
      originals = protected.to_h { [_1, File.binread(File.join(root, _1))] }

      protected.each do |path|
        result = run_cli(root, ["collate", "artifacts/paid.json", "--manifest", "shards.json", "--output", path])
        assert_equal 2, result[:status].exitstatus, path
        assert_includes result[:stderr], "must not overwrite", path
        assert_equal originals.fetch(path), File.binread(File.join(root, path)), path
      end
    end
  end

  def test_failed_shard_remains_failed_and_output_is_preserved_on_incompatibility
    with_project do |root|
      write_boolean_project(root, framework: :minitest)
      failed = analyze(root, "test/failing_test.rb", output: "artifacts/failed.json")
      assert_equal 1, failed[:status].exitstatus
      assert_equal "FAILED", failed.dig(:json, "baseline", "status")
      write_manifest(root, ["failed"])
      collated = run_cli(root, ["collate", "artifacts/failed.json", "--manifest", "shards.json"])
      assert_equal 1, collated[:status].exitstatus, collated[:stderr]
      assert_equal "FAILED", JSON.parse(collated[:stdout]).dig("baseline", "status")

      original = File.binread(File.join(root, "artifacts", "failed.json"))
      invalid = JSON.parse(original)
      invalid["tool_version"] = "999.0"
      File.write(File.join(root, "artifacts", "invalid.json"), JSON.generate(invalid))
      File.write(File.join(root, "output.json"), "preserve me")
      incompatible = run_cli(root, ["collate", "artifacts/invalid.json", "--output", "output.json"])
      assert_equal 2, incompatible[:status].exitstatus
      assert_equal "preserve me", File.read(File.join(root, "output.json"))
      assert_empty Dir.glob(File.join(root, "output.json.tmp-*"))
    end
  end

  def test_cli_rejects_missing_inputs_unknown_options_and_bad_formats
    with_project do |root|
      assert_equal 2, run_cli(root, ["collate"])[:status].exitstatus
      assert_equal 2, run_cli(root, ["collate", "input.json", "--unknown"])[:status].exitstatus
      assert_equal 2, run_cli(root, ["collate", "input.json", "--format", "xml"])[:status].exitstatus
      assert_includes run_cli(root, ["collate", "--help"])[:stdout], "branchproof collate REPORT..."
    end
  end

  private

  def with_project(&)
    Dir.mktmpdir("branchproof-collation-acceptance-", &)
  end

  def write_boolean_project(root, framework:)
    FileUtils.mkdir_p(File.join(root, "lib"))
    File.write(File.join(root, "lib", "decision.rb"), <<~RUBY)
      def branchproof_allowed?(paid, suspended)
        if paid && !suspended
          true
        else
          false
        end
      end
    RUBY
    if framework == :minitest
      FileUtils.mkdir_p(File.join(root, "test"))
      %w[paid suspended].each do |kind|
        paid = kind == "paid"
        File.write(File.join(root, "test", "#{kind}_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require #{File.join(root, "lib", "decision.rb").inspect}
          class #{kind.capitalize}Test < Minitest::Test
            def test_observation
              assert_equal #{paid}, branchproof_allowed?(true, #{!paid})
            end
          end
        RUBY
      end
      File.write(File.join(root, "test", "failing_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require #{File.join(root, "lib", "decision.rb").inspect}
        class CollationFailureTest < Minitest::Test
          def test_fails
            branchproof_allowed?(true, false)
            flunk "expected failure"
          end
        end
      RUBY
    else
      FileUtils.mkdir_p(File.join(root, "spec"))
      File.write(File.join(root, "spec", "spec_helper.rb"), "require \"rspec/expectations\"\n")
      File.write(File.join(root, ".rspec"), "--require spec_helper\n--format progress\n")
      %w[paid suspended].each do |kind|
        paid = kind == "paid"
        File.write(File.join(root, "spec", "#{kind}_spec.rb"), <<~RUBY)
          require "decision"
          RSpec.describe "#{kind}" do
            it "records a decision" do
              expect(branchproof_allowed?(true, #{!paid})).to eq(#{paid})
            end
          end
        RUBY
      end
    end
  end

  def analyze(root, *tests, framework: "minitest", output: nil, arguments: [])
    args = ["analyze", "lib/decision.rb", "--framework", framework, "--format", "json"]
    tests.each { args.push("--test", _1) }
    args.concat(arguments)
    FileUtils.mkdir_p(File.dirname(File.join(root, output))) if output
    args.push("--output", output) if output
    result = run_cli(root, args)
    json_path = output && File.join(root, output)
    result[:json] = if json_path && File.file?(json_path)
                      JSON.parse(File.read(json_path))
                    else
                      JSON.parse(result[:stdout])
                    end
    result
  end

  def git(root, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: root)
    assert status.success?, "git #{args.join(" ")} failed: #{stdout}#{stderr}"
  end

  def write_manifest(root, ids)
    FileUtils.mkdir_p(File.join(root, "artifacts"))
    shards = ids.map { |id| { id: id, report: "artifacts/#{id}.json" } }
    File.write(File.join(root, "shards.json"), JSON.generate(shards: shards))
  end

  def run_cli(root, args)
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *args, chdir: root)
    { stdout: stdout, stderr: stderr, status: status }
  end
end
