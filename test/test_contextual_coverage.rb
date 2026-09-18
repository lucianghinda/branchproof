# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestContextualCoverage < Minitest::Test
  def test_flip_flop_is_supported_and_keeps_native_state_across_calls
    source = <<~RUBY
      def self.exercise(values)
        values.filter_map do |value|
          value if (value == 1)..(value == 3)
        end
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decision = inventory[:decisions].find { |entry| entry[:kind] == "boolean" && entry[:expression].include?("..") }

    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_flip_flop"
    assert_equal 1, decision[:conditions].length
    arguments = [[0, 1, 2, 3, 4], [0, 1, 2, 3, 4]]
    assert_equal native_results(source, arguments), rewritten_results(rewritten[:bytes], arguments)
  end

  def test_implicit_regexp_rewrite_preserves_ruby_s_implicit_match
    source = <<~RUBY
      def self.exercise(text)
        $_ = text
        if /needle/
          :match
        else
          :miss
        end
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decision = inventory[:decisions].find { |entry| entry[:expression] == "/needle/" }

    assert_equal "SUPPORTED", decision[:support_status]
    refute_includes decision[:support_reasons], "unsupported_implicit_regexp"
    assert_includes rewritten[:bytes], "if (/needle/)"
    arguments = %w[needle nope]
    assert_equal native_results(source, arguments), rewritten_results(rewritten[:bytes], arguments)
  end

  def test_implicit_regexp_keeps_regexp_receiver_dispatch
    source = <<~RUBY
      class Probe
        def to_str = "needle"
        def =~(*) = false
      end

      def self.exercise
        $_ = Probe.new
        /needle/ ? :match : :miss
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    assert_equal :match, native_results(source, [nil]).first
    assert_equal native_results(source, [nil]), rewritten_results(rewritten[:bytes], [nil])
    assert_equal :match, rewritten_results(rewritten[:bytes], [nil]).first
    assert_equal "SUPPORTED", inventory[:decisions].find { |entry| entry[:expression] == "/needle/" }[:support_status]
  end

  def test_defined_expression_is_one_atomic_decision_and_prunes_unevaluated_operands
    source = <<~RUBY
      def self.exercise
        defined?(missing_catalog_method && (raise "must not run"))
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)
    decisions = inventory[:decisions]

    assert_equal 1, decisions.length
    assert_equal "defined", decisions.first[:context]
    assert_equal "defined?(missing_catalog_method && (raise \"must not run\"))", decisions.first[:expression]
    assert_equal(["defined?(missing_catalog_method && (raise \"must not run\"))"],
                 decisions.first[:conditions].map { |condition| condition[:expression] })
    assert_equal "SUPPORTED", decisions.first[:support_status]
    assert_empty decisions.first[:support_reasons]
    assert_equal native_results(source, [nil, nil]), rewritten_results(rewritten[:bytes], [nil, nil])
  end

  def test_defined_expression_prunes_nested_conditional_and_flow_nodes
    source = <<~RUBY
      def self.exercise
        defined?(if true
                    raise "must not run"
                  else
                    :value
                  end)
      end
    RUBY

    inventory, rewritten = inventory_and_rewrite(source)

    assert_equal 1, inventory[:decisions].length
    assert_equal "defined", inventory[:decisions].first[:context]
    assert_equal "SUPPORTED", inventory[:decisions].first[:support_status]
    assert_equal native_results(source, [nil]), rewritten_results(rewritten[:bytes], [nil])
  end

  private

  def inventory_and_rewrite(source)
    Dir.mktmpdir("branchproof-contextual") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default)
                                     .inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics]
      assert rewritten[:changed]
      return [inventory, rewritten]
    end
  end

  def native_results(source, arguments)
    mod = Module.new
    mod.module_eval(source)
    arguments.map { |argument| argument.nil? ? mod.exercise : mod.exercise(argument) }
  end

  def rewritten_results(source, arguments)
    mod = Module.new
    mod.module_eval(runtime_stub + source)
    arguments.map { |argument| argument.nil? ? mod.exercise : mod.exercise(argument) }
  end

  def runtime_stub
    <<~RUBY
      module Branchproof
        module Runtime
          def self.enter(*) = nil
          def self.condition(_, _, value) = value
          def self.finish(_, value) = value
          def self.leave(*) = nil
        end
      end
    RUBY
  end
end
