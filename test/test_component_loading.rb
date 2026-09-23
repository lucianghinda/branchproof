# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

class TestComponentLoading < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def test_main_entrypoint_exposes_report_selection_via_autoload
    stdout, stderr, status = run_script(<<~RUBY)
      require "branchproof"
      selection = Branchproof::ReportSelection.new(top: 1)
      abort "missing selection" unless selection.top == 1
      puts "ok"
    RUBY

    assert status.success?, stderr
    assert_equal "ok\n", stdout
  end

  def test_report_loads_policy_when_required_as_a_standalone_component
    stdout, stderr, status = run_script(<<~RUBY)
      require "json"
      require "stringio"
      require "branchproof/report"
      report = Branchproof::Report.new(
        inventory: { decisions: [] }, evidence: { vectors: [], completeness: { observation: true, attribution: true, analysis: true } },
        analysis: { coverage: { mcdc: { proven_conditions: 0, supported_conditions: 0 } }, completeness: { observation: true, attribution: true, analysis: true } },
        minima: [], baseline: { status: "PASSED", finalized: true }, diagnostics: [], minimum: { mcdc: 0 }
      )
      io = StringIO.new
      report.write(io: io, format: :json)
      puts JSON.parse(io.string).fetch("coverage_policy").fetch("status")
    RUBY

    assert status.success?, stderr
    assert_equal "unavailable\n", stdout
  end

  def test_saved_report_loads_policy_when_required_as_a_standalone_component
    stdout, stderr, status = run_script(<<~RUBY)
      require "branchproof/saved_report"
      puts Branchproof::SavedReport::SUPPORTED_SCHEMAS.include?("1.4")
    RUBY

    assert status.success?, stderr
    assert_equal "true\n", stdout
  end

  private

  def run_script(script)
    Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)
  end
end
