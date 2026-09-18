# frozen_string_literal: true

require "test_helper"
require "prism"
require "branchproof/decision_syntax"
require "branchproof/exception_syntax"

class TestFlowSource < Minitest::Test
  class Harness
    include Branchproof::DecisionSyntax
    include Branchproof::ExceptionSyntax

    def walk(node, &block)
      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end

    def text_value(value, encoding)
      value.dup.force_encoding(encoding).encode("UTF-8")
    end

    def unsupported_reasons(*)
      []
    end
  end

  def setup
    @source = Harness.new
  end

  def decisions(source)
    parsed = Prism.parse(source)
    assert_empty parsed.errors
    @source.flow_decisions_for(parsed.value, source, "source-1")
  end

  def test_records_each_normal_case_candidate_and_branch_boundary
    source = <<~RUBY
      case value
      when first, second
        :first
      when third
        :third
      else
        :other
      end
    RUBY

    decision = decisions(source).fetch(0)

    assert_equal "multiway", decision[:kind]
    assert_equal "case", decision[:context]
    assert_equal(%w[first second third else], decision[:alternatives].map { |item| item[:expression] })
    assert_equal 3, decision[:instrumentation][:candidates].length
    assert_equal 2, decision[:instrumentation][:branches].length
    assert_equal source.index(":first"), decision[:instrumentation][:branches][0][:insert_at]
    assert_equal source.index(":third"), decision[:instrumentation][:branches][1][:insert_at]
    assert_equal source.index(":other"), decision[:instrumentation][:else][:insert_at]
    assert_equal source.rstrip, source.byteslice(decision[:byte_start], decision[:byte_length])
    assert_equal [], decision[:conditions]
  end

  def test_records_pattern_case_guard_as_supported_with_native_ranges
    source = <<~RUBY
      case value
      in {name: pattern} if guard
        :matched
      else
        :other
      end
    RUBY

    decision = decisions(source).fetch(0)

    assert_equal "pattern", decision[:kind]
    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_pattern_guard"
    candidate = decision[:instrumentation][:candidates].fetch(0)
    assert_equal "{name: pattern}", candidate[:expression]
    assert_equal source.index("{name: pattern}"), candidate[:byte_start]
    assert_equal source.index(":matched"), decision[:instrumentation][:branches][0][:insert_at]
    assert_equal source.index(":other"), decision[:instrumentation][:else][:insert_at]
  end

  def test_unless_pattern_guard_is_supported
    decision = decisions("case value; in Integer unless excluded; :yes; else :no; end").first
    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_pattern_guard"
    assert_equal "Integer", decision[:alternatives].first[:expression]
  end

  def test_safe_navigation_inside_a_normal_assignment_receiver_is_supported
    records = decisions("receiver&.child.value ||= fallback")
    assignment = records.find { |record| record[:context] == "or_assignment" }
    assert_equal "SUPPORTED", assignment[:support_status]
  end

  def test_records_standalone_in_safe_navigation_and_all_short_circuit_assignments
    source = <<~RUBY
      first&.ready?
      local ||= fallback
      @instance &&= fallback
      @@class ||= fallback
      $global &&= fallback
      Constant ||= fallback
      Namespace::Constant &&= fallback
      receiver.value ||= fallback
      values[index] &&= fallback
      object&.value ||= fallback
    RUBY

    records = decisions(source)
    assert_equal 10, records.length
    assert_equal "safe_navigation", records[0][:context]
    assert_equal(%w[or_assignment and_assignment or_assignment and_assignment or_assignment and_assignment or_assignment and_assignment or_assignment],
                 records.drop(1).map { |record| record[:context] })
    assert_equal 1, records[1][:instrumentation][:rhs_path]
    assert_equal 1, records[2][:instrumentation][:rhs_path]
    assert_equal "SUPPORTED", records.first[:support_status]
    assert_equal "SUPPORTED", records.last[:support_status]
  end

  def test_records_rescue_control_flow_as_supported
    source = "begin\n  work\nrescue StandardError\n  recover\nend\n"
    decision = decisions(source).fetch(0)

    assert_equal "exception", decision[:kind]
    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_rescue_control_flow"
  end

  def test_records_splat_case_candidate_for_instrumentation
    source = "case value\nwhen *candidates\n  :matched\nend\n"
    decision = decisions(source).fetch(0)

    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_case_splat"
    assert_equal "*candidates", decision[:alternatives].fetch(0)[:expression]
  end
end
