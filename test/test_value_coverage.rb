# frozen_string_literal: true

require "test_helper"
require "prism"
require_relative "../lib/branchproof/value_syntax"
require_relative "../lib/branchproof/value_runtime"
require "tmpdir"
require_relative "support/ruby_constructs"

class TestValueCoverage < Minitest::Test
  class SyntaxProbe
    include Branchproof::ValueSyntax

    def walk(node, &block)
      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end

    def text_value(value, _encoding)
      value
    end
  end

  class RuntimeProbe
    include Branchproof::ValueRuntime

    attr_reader :frame

    def initialize
      @frame = { alternative_count: 4, observations: [], finished: false }
    end

    def current_frame(_decision_id)
      @frame
    end
  end

  class IntegratedSource < Branchproof::Source
    prepend Branchproof::ValueSyntax
  end

  def test_inventory_classifies_value_domains_without_treating_less_than_equal_as_short_circuit
    source = <<~RUBY
      def example(value, method_name)
        [value == 1, value <=> 1, value["x"], value & 1, value.public_send(method_name)]
      end
    RUBY
    program = Prism.parse(source).value
    decisions = SyntaxProbe.new.value_decisions_for(program, source, "source")
    assert_equal %w[comparison dispatch lookup predicate].sort,
                 decisions.map { |decision| decision.fetch(:context) }.sort
    assert_equal %w[multiway multiway implicit implicit].sort,
                 decisions.map { |decision| decision.fetch(:kind) }.sort
  end

  def test_runtime_uses_prefix_trace_and_preserves_unexpected_comparison_values
    probe = RuntimeProbe.new
    value = probe.value_path("id", -1, "comparison")
    assert_equal(-1, value)
    assert_equal [[0, true]], probe.frame.fetch(:observations)

    probe.frame[:observations] = []
    custom = Object.new
    def custom.<=>(_other) = Object.new
    assert_same custom, probe.value_path("id", custom, "comparison")
    assert_empty probe.frame.fetch(:observations)
  end

  def test_real_inventory_rewrite_and_evidence_cover_plain_predicates
    Dir.mktmpdir("branchproof-value-") do |root|
      source_path = File.join(root, "construct.rb")
      File.write(source_path, <<~RUBY)
        def example(left, right)
          [left == right, left != right, left.eql?(right), left.equal?(right)]
        end
      RUBY
      source = IntegratedSource.new(root: root, limits: Branchproof::Limits.default)
      inventory = source.inventory(paths: ["construct.rb"])
      decisions = inventory.fetch(:decisions)
      refute_empty decisions
      assert(decisions.all? { |decision| decision.fetch(:kind) == "implicit" })

      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory.fetch(:source_units).first)
      assert rewritten.fetch(:changed)
      assert_empty rewritten.fetch(:diagnostics)

      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                           run_id: "value-test")
      evidence.register_test(test: { id: "value-test", name: "value-test", adapter: "test" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "value-test", phase: "body")
      runner = Object.new
      namespace = Module.new
      namespace.module_eval(rewritten.fetch(:bytes), source_path, 1)
      runner.extend(namespace)
      runner.example(1, 1)
      runner.example(1, 2)

      snapshot = evidence.snapshot
      assert_equal decisions.map { |decision| decision.fetch(:id) }.sort,
                   snapshot.fetch(:vectors).map { |vector| vector.fetch(:decision_id) }.uniq.sort
      analysis = Branchproof::Analyzer.new(inventory: inventory, evidence: snapshot,
                                           limits: Branchproof::Limits.default).call
      analysis.fetch(:decisions).each do |row|
        assert_equal "covered", row.dig(:coverage, :alternative, :status)
      end
    end
  ensure
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
  end

  def test_corpus_predicates_and_dynamic_dispatch_preserve_native_results_without_invalid_vectors
    ids = (1..17).map { |number| format("PRED-%02d", number) } + %w[API-01 API-09 API-10]
    ids.each do |id|
      RubyConstructs.entry(id).fetch("cases").each do |sample|
        captured = RubyConstructs.capture(id, sample)
        expected = sample.key?("error") ? { "error" => sample.fetch("error") } : { "result" => sample.fetch("result") }
        assert_equal expected, captured.fetch(:result), "#{id}/#{sample.fetch("name")}"
        invalid = captured.fetch(:diagnostics).select { |diagnostic| diagnostic[:code].to_s == "invalid_execution" }
        assert_empty invalid, "#{id}/#{sample.fetch("name")}: #{invalid.inspect}"
      end
    end
  end
end
