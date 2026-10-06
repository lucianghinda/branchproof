# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class GuardAcceptanceTest < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/branchproof", __dir__)
  GATES = %w[mcdc decision condition decision_table].freeze

  def test_raise_and_return_guards_pass_all_gates_and_saved_reports_round_trip
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      def checked(value)
        value || raise(ArgumentError, "missing")
      end

      def returned(value)
        value || return
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_present
          assert_equal :present, checked(:present)
          assert_equal :present, returned(:present)
        end

        def test_missing
          assert_raises(ArgumentError) { checked(false) }
          assert_nil returned(nil)
        end
      end
    RUBY
      result = analyze(root, "--output", "saved.json")
      assert_success(result)
      saved = JSON.parse(File.read(File.join(root, "saved.json")))
      assert_guard_evidence(saved, 2)
      missing_test = saved.dig("observations", "tests").find { |test| test.fetch("method_name") == "test_missing" }
      refute_nil missing_test
      guard_decisions(saved).each do |decision|
        false_vector = saved.dig("observations", "vectors").find do |vector|
          vector.fetch("decision_id") == decision.fetch("id") && vector.fetch("outcome") == false
        end
        assert_equal [missing_test.fetch("id")], false_vector.fetch("test_ids")
      end
      assert_equal "passed", saved.dig("coverage_policy", "status")
      assert_equal GATES.sort, saved.dig("coverage_policy", "gates").map { |gate| gate.fetch("criterion") }.sort

      replay = cli(root, "report", "saved.json", "--format", "json")
      assert_success(replay)
      assert_equal saved.fetch("source_inventory"), replay.fetch(:json).fetch("source_inventory")
      assert_equal saved.fetch("observations"), replay.fetch(:json).fetch("observations")
      assert_equal saved.fetch("analysis"), replay.fetch(:json).fetch("analysis")

      terminal = cli(root, "report", "saved.json", "--format", "terminal")
      assert_success(terminal)
      assert_includes terminal.fetch(:stdout), "PROVEN"
      refute_includes terminal.fetch(:stdout), "NOT PROVEN"
    end
  end

  def test_missing_guard_path_fails_every_coverage_gate
    with_project(source: "def checked(value)\n  value || raise('missing')\nend\n", tests: <<~RUBY) do |root|
      class GuardTest < Minitest::Test
        def test_present
          assert_equal :present, checked(:present)
        end
      end
    RUBY
      result = analyze(root)
      assert_equal 1, result.fetch(:status).exitstatus, result.fetch(:stderr)
      assert_equal "PASSED", result.dig(:json, "baseline", "status")
      assert_equal "failed", result.dig(:json, "coverage_policy", "status")
      assert_equal(["failed"] * GATES.length, result.dig(:json, "coverage_policy", "gates").map { |gate| gate.fetch("status") })
    end
  end

  def test_overridden_raise_preserves_false_nil_and_truthy_return_values
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      class CustomGuard
        attr_reader :calls

        def initialize(result)
          @result = result
          @calls = 0
        end

        def raise
          @calls += 1
          @result
        end

        def checked(value)
          value || raise
        end
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_values_and_evaluation_count
          [false, nil, Object.new].each do |result|
            guard = CustomGuard.new(result)
            assert_same result, guard.checked(false)
            assert_equal 1, guard.calls
            assert_equal :present, guard.checked(:present)
            assert_equal 1, guard.calls
          end
        end
      end
    RUBY
      result = analyze(root)
      assert_success(result)
      assert_guard_evidence(result.fetch(:json), 1)
    end
  end

  def test_raise_keeps_exception_identity_and_ensure_execution
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      def checked(value, exception, events)
        value || fail(exception)
      ensure
        events << :ensured
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_exception_and_success
          events = []
          exception = ArgumentError.new("missing")
          assert_same exception, assert_raises(ArgumentError) { checked(false, exception, events) }
          assert_equal :present, checked(:present, exception, events)
          assert_equal [:ensured, :ensured], events
        end
      end
    RUBY
      result = analyze(root)
      assert_success(result)
      assert_guard_evidence(result.fetch(:json), 1)
    end
  end

  def test_break_next_and_compound_guards_keep_control_flow_and_condition_evidence
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      def stop_at_missing(values)
        values.each do |value|
          value || (break :missing)
        end
      end

      def replace_missing(values)
        values.map do |value|
          value || (next :missing)
        end
      end

      def both(left, right)
        (left && right) || (return :missing)
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_guards
          assert_equal :missing, stop_at_missing([true, false, :unreached])
          assert_equal [true, :missing], replace_missing([true, false])
          assert_equal :missing, both(false, true)
          assert_equal :missing, both(true, false)
          assert_equal true, both(true, true)
        end
      end
    RUBY
      result = analyze(root)
      assert_success(result)
      guards = guard_decisions(result.fetch(:json))
      assert_equal 3, guards.length
      compound = guards.find { |decision| decision.fetch("conditions").length == 2 }
      refute_nil compound
      assert_equal "and", compound.fetch("tree").fetch("type")
      analysis = result.dig(:json, "analysis", "decisions").find { |decision| decision.fetch("decision_id") == compound.fetch("id") }
      assert_equal(%w[PROVEN PROVEN], analysis.fetch("condition_results").map { |condition| condition.fetch("status") })
      assert_equal 0, result.dig(:json, "metrics", "aborted")
    end
  end

  def test_nested_return_argument_records_its_own_boolean_evidence
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      def checked(value, left, right)
        value || (return left && right)
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_present
          assert_equal :present, checked(:present, false, false)
        end

        def test_returned_boolean
          assert_equal false, checked(nil, false, true)
          assert_equal false, checked(nil, true, false)
          assert_equal true, checked(nil, true, true)
        end
      end
    RUBY
      result = analyze(root)
      assert_success(result)
      report = result.fetch(:json)
      assert_guard_evidence(report, 1)
      inner = report.dig("source_inventory", "decisions").find { |decision| decision.fetch("context") == "short_circuit" }
      refute_nil inner
      assert_equal 2, inner.fetch("conditions").length
      vectors = report.dig("observations", "vectors").select { |vector| vector.fetch("decision_id") == inner.fetch("id") }
      assert_equal 3, vectors.length
      owner = report.dig("observations", "tests").find { |test| test.fetch("method_name") == "test_returned_boolean" }
      assert_equal [owner.fetch("id")], vectors.flat_map { |vector| vector.fetch("test_ids") }.uniq
    end
  end

  def test_exception_in_left_predicate_does_not_count_as_a_false_guard_outcome
    with_project(source: <<~RUBY, tests: <<~RUBY) do |root|
      def checked(callback)
        callback.call || raise("missing")
      end
    RUBY
      class GuardTest < Minitest::Test
        def test_completed_predicate
          assert_equal :present, checked(-> { :present })
        end

        def test_aborted_predicate
          error = assert_raises(ArgumentError) { checked(-> { raise ArgumentError, "predicate failed" }) }
          assert_equal "predicate failed", error.message
        end
      end
    RUBY
      result = analyze(root)
      assert_equal 1, result.fetch(:status).exitstatus, result.fetch(:stderr)
      report = result.fetch(:json)
      assert_equal "PASSED", report.dig("baseline", "status")
      assert_equal "failed", report.dig("coverage_policy", "status")
      assert_equal(["failed"] * GATES.length, report.dig("coverage_policy", "gates").map { |gate| gate.fetch("status") })
      guards = guard_decisions(report)
      assert_equal 1, guards.length
      vectors = report.dig("observations", "vectors").select { |vector| vector.fetch("decision_id") == guards.first.fetch("id") }
      assert_equal([true], vectors.map { |vector| vector.fetch("outcome") })
      assert_operator report.dig("metrics", "aborted"), :>, 0
    end
  end

  private

  def assert_success(result)
    assert_equal 0, result.fetch(:status).exitstatus, "#{result.fetch(:stderr)}\n#{result.fetch(:stdout)}"
  end

  def guard_decisions(report)
    report.fetch("source_inventory").fetch("decisions").select { |decision| decision.fetch("context") == "guard" }
  end

  def assert_guard_evidence(report, count)
    guards = guard_decisions(report)
    assert_equal count, guards.length
    guards.each do |decision|
      assert_equal 1, decision.fetch("conditions").length
      vectors = report.fetch("observations").fetch("vectors").select { |vector| vector.fetch("decision_id") == decision.fetch("id") }
      assert_equal([false, true], vectors.map { |vector| vector.fetch("outcome") }.sort_by { |value| value ? 1 : 0 })
    end
    assert_equal 0, report.fetch("metrics").fetch("aborted")
  end

  def analyze(root, *)
    cli(root, "analyze", "lib/guard.rb", "--test", "test/guard_test.rb", "--level", "3", "--format", "json",
        *GATES.flat_map { |gate| ["--minimum", "#{gate}=100"] }, *)
  end

  def cli(root, *)
    stdout, stderr, status = Open3.capture3({ "MT_NO_PLUGINS" => "1" }, RbConfig.ruby, EXECUTABLE, *, chdir: root)
    { stdout: stdout, stderr: stderr, status: status, json: stdout.start_with?("{") ? JSON.parse(stdout) : nil }
  end

  def with_project(source:, tests:)
    Dir.mktmpdir("branchproof-guard-acceptance-") do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "lib", "guard.rb"), source)
      File.write(File.join(root, "test", "guard_test.rb"), "require_relative '../lib/guard'\nrequire 'minitest/autorun'\n#{tests}")
      yield root
    end
  end
end
