# frozen_string_literal: true

require "json"
require "stringio"
require "test_helper"
require "branchproof/report"
require "branchproof/saved_report"
require "branchproof/comparison"
require_relative "support/ruby_constructs"

class TestRubyConstructReporting < Minitest::Test
  VIEWS = Branchproof::Report::VIEWS.freeze
  LEVELS = [1, 2, 3].freeze
  def self.document_cache
    @document_cache ||= {}
  end

  def test_every_fixture_renders_each_level_view_and_missing_only
    RubyConstructs.entries.each do |entry|
      document = document_for(entry.fetch("id"))
      analysis = Marshal.dump(document.fetch(:analysis))

      LEVELS.each do |level|
        VIEWS.each do |view|
          output = render(document, level: level, view: view)
          refute_empty output, "#{entry.fetch("id")} level #{level} #{view}"
          assert_rendered_coverage(document, output, entry.fetch("id"))

          next if level == 1

          filtered = render(document, level: level, view: view, missing_only: true)
          refute_empty filtered, "#{entry.fetch("id")} level #{level} #{view} missing-only"
          assert_rendered_coverage(document, filtered, entry.fetch("id"))
        end
      end

      assert_equal analysis, Marshal.dump(document.fetch(:analysis)), entry.fetch("id")
      assert_report_population(document, entry.fetch("id"))
    end
  end

  def test_levels_expose_progressively_specific_evidence_anchors
    RubyConstructs.entries.each do |entry|
      document = document_for(entry.fetch("id"))
      level_one = render(document, level: 1)
      level_two = render(document, level: 2)
      level_three = render(document, level: 3)

      assert_includes level_one, "Analysis:"
      assert_includes level_one, "Decisions:"
      next unless entry.fetch("id") == "LOG-01"

      refute_includes level_one, "witness"
      assert_includes level_two, "Value true:"
      assert_includes level_two, "Outcome false:"
      assert_includes level_three, "witness"
    end
  end

  def test_saved_report_roundtrip_preserves_rendering_contract_for_every_fixture
    RubyConstructs.entries.each do |entry|
      id = entry.fetch("id")
      document = saved_document(document_for(id))
      validated = Branchproof::SavedReport.new(document).validate!
      assert_equal document, validated, id

      output = render_saved(document, level: 3, view: :conditions)
      refute_empty output, id
      eligible = document.dig("metrics", "eligible_conditions").to_i.positive? ||
                 document.dig("metrics", "eligible_alternatives").to_i.positive?
      status = document.dig("baseline", "status").to_s.upcase
      expected_exit = if status == "FAILED"
                        1
                      elsif status != "PASSED" || document.dig("baseline", "finalized") != true ||
                            document.fetch("completeness").values.include?(false) || !eligible
                        2
                      else
                        0
                      end
      assert_equal expected_exit, Branchproof::Report.from_document(document: document, level: 3).exit_code, id
    end
  end

  def test_missing_only_removes_proven_conditions_and_covered_table_rules
    samples = RubyConstructs.entry("LOG-01").fetch("cases").select do |sample|
      ["left false", "both truthy"].include?(sample.fetch("name"))
    end
    partial = document_for("LOG-01", cases: samples)
    [2, 3].each do |level|
      full = render(partial, level: level, view: :conditions)
      missing = render(partial, level: level, view: :conditions, missing_only: true)
      assert_includes full, "Condition: left\n"
      refute_includes missing, "Condition: left\n"
      assert_includes missing, 'Condition: (trace << "right"; right)'
      assert_rendered_coverage(partial, missing, "LOG-01 partial")

      complete = render(document_for("LOG-01"), level: level, missing_only: true)
      refute_includes complete, "Condition 0:"
      refute_includes complete, "Condition 1:"
      full_table = render(partial, level: level, view: :decision_tables)
      missing_table = render(partial, level: level, view: :decision_tables, missing_only: true)
      assert_equal 2, full_table.lines.grep(/^  R\d+ .*  COVERED$/).length
      assert_empty missing_table.lines.grep(/^  R\d+ .*  COVERED$/)
      assert_equal ["  R2 TF => F  MISSING\n"], missing_table.lines.grep(/^  R\d+/)
    end
  end

  def test_comparison_keeps_denominators_for_boolean_alternative_and_excluded_shapes
    identical = %w[LOG-01 NIL-01 FLIP-01 ARG-01]
    identical.each do |id|
      document = saved_document(document_for(id))
      result = Branchproof::Comparison.new(before: document, after: document).call
      expected_status = %w[LOG-01 FLIP-01].include?(id) ? "complete" : "comparison incomplete"
      assert_equal expected_status, result.fetch("status"), id
      assert_equal 0, result.fetch("regressions"), id
      assert_empty result.fetch("changes").reject { |change| change.fetch("change") == "unchanged" }, id
      assert_includes result.fetch("reasons"), "no comparable conditions", id unless %w[LOG-01 FLIP-01].include?(id)
    end

    before = saved_document(document_for("LOG-01"))
    reduced = saved_document(document_for("LOG-01", cases: RubyConstructs.entry("LOG-01").fetch("cases").first(1)))
    result = Branchproof::Comparison.new(before: before, after: reduced).call
    assert_equal "complete", result.fetch("status")
    assert_equal 2, result.fetch("regressions")
    assert_equal 2, result.dig("matching", "denominator")
    changes = result.fetch("changes").map { |change| change.fetch("change") }
    assert_equal ["lost proof", "lost proof"], changes

    %w[NIL-01 ARG-01].each do |id|
      document = saved_document(document_for(id))
      reduced = saved_document(document_for(id, cases: RubyConstructs.entry(id).fetch("cases").first(1)))
      result = Branchproof::Comparison.new(before: document, after: reduced).call
      assert_equal "comparison incomplete", result.fetch("status"), id
      assert_includes result.fetch("reasons"), "no comparable conditions", id
      assert_equal 0, result.dig("matching", "denominator"), id
      assert_equal 0, result.fetch("regressions"), id
    end
  end

  private

  def document_for(id, **options)
    cache = self.class.document_cache
    return cache[id] if options.empty? && cache.key?(id)

    document = RubyConstructs.document(id, **options)
    cache[id] = document if options.empty?
    document
  end

  def render(document, level:, view: :decisions, missing_only: false)
    output = StringIO.new
    Branchproof::Report.new(inventory: document.fetch(:inventory), evidence: document.fetch(:evidence),
                            analysis: document.fetch(:analysis), minima: [], baseline: baseline_for(document),
                            diagnostics: document.fetch(:diagnostics, []), level: level, view: view,
                            missing_only: missing_only).write(io: output, format: :terminal)
    output.string
  end

  def render_saved(document, level:, view: :decisions)
    output = StringIO.new
    Branchproof::Report.from_document(document: document, level: level, view: view).write(io: output, format: :terminal)
    output.string
  end

  def saved_document(document)
    output = StringIO.new
    Branchproof::Report.new(inventory: document.fetch(:inventory), evidence: document.fetch(:evidence),
                            analysis: document.fetch(:analysis), minima: [],
                            baseline: baseline_for(document),
                            diagnostics: document.fetch(:diagnostics, []),
                            run_metadata: { project_kind: "ruby", source_patterns: ["fixtures/**/*.rb"],
                                            test_patterns: ["fixtures/**/*"], test_files: [], runner_args: [], limits: {} }).write(
                                              io: output, format: :json
                                            )
    JSON.parse(output.string)
  end

  def baseline_for(document)
    document[:baseline] || { status: "PASSED", finalized: true }
  end

  def assert_report_population(document, id)
    inventory_decisions = document.fetch(:inventory).fetch(:decisions)
    analysis_decisions = document.fetch(:analysis).fetch(:decisions)
    assert_equal inventory_decisions.length, analysis_decisions.length, id
    coverage = document.fetch(:analysis).fetch(:coverage)
    %i[decision condition condition_decision mcdc alternative].each do |criterion|
      assert coverage.key?(criterion), "#{id} missing #{criterion} aggregate"
    end
    supported_boolean = inventory_decisions.count do |decision|
      decision.fetch(:kind, "boolean").to_s == "boolean" && decision[:support_status].to_s.upcase != "UNSUPPORTED"
    end
    assert_equal supported_boolean, coverage.dig(:decision, :supported_decisions), id
    required_alternatives = inventory_decisions.sum do |decision|
      next 0 if decision[:support_status].to_s.upcase == "UNSUPPORTED"

      decision.fetch(:kind, "boolean").to_s == "boolean" ? 0 : Array(decision[:alternatives]).length
    end
    assert_equal required_alternatives, coverage.dig(:alternative, :required_alternatives), id
  end

  def assert_rendered_coverage(document, output, id)
    assert_includes output, "Tests: #{document.fetch(:baseline).fetch(:status)}", id
    coverage = document.fetch(:analysis).fetch(:coverage)
    {
      "D (Decision coverage)" => [:decision, :covered_decisions, :supported_decisions, "decisions"],
      "C (Condition coverage)" => [:condition, :covered_values, :required_values, "truth values"],
      "C/D (Condition/decision coverage)" => [:condition_decision, :covered_decisions, :supported_decisions, "decisions"],
      "MC/DC (MC/DC coverage)" => [:mcdc, :proven_conditions, :supported_conditions, "conditions"],
      "DT (Decision table coverage)" => [:decision_table, :covered_rules, :required_rules, "rules"]
    }.each do |label, (criterion, numerator, denominator, unit)|
      row = coverage.fetch(criterion)
      assert_match(%r{#{Regexp.escape(label)}: .*\(#{row.fetch(numerator)}/#{row.fetch(denominator)} #{unit}\)},
                   output, id)
    end
    alternatives = coverage.fetch(:alternative)
    assert_includes output,
                    "Alternative coverage: #{alternatives.fetch(:covered_alternatives)}/#{alternatives.fetch(:required_alternatives)} alternatives", id
  end
end
