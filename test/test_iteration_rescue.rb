# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestIterationRescue < Minitest::Test
  SOURCE = <<~RUBY
    def self.block_rescue(values)
      values.filter_map do |value|
        Integer(value)
      rescue ArgumentError
        nil
      end
    end

    def self.block_ensure(values)
      cleaned = []
      values.filter_map do |value|
        cleaned << value
        value if value
      ensure
        cleaned << :finished
      end
    end

    def self.explicit_begin(values)
      values.filter_map do |value|
        begin
          Integer(value)
        rescue ArgumentError
          nil
        end
      end
    end
  RUBY

  def test_implicit_rescue_and_ensure_blocks_rewrite_and_preserve_values
    Dir.mktmpdir("branchproof-iteration-rescue") do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, SOURCE)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)

      assert_empty rewritten[:diagnostics]
      assert_empty Prism.parse(rewritten[:bytes]).errors

      native = Module.new
      measured = Module.new
      native.module_eval(SOURCE, path)
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                           run_id: "iteration-rescue")
      evidence.register_test(test: { id: "IterationRescue#exercise", name: "exercise", adapter: "minitest" })
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: "IterationRescue#exercise", phase: "body")
      measured.module_eval(rewritten[:bytes], path)

      values = %w[1 bad 2]
      assert_equal native.block_rescue(values), measured.block_rescue(values)
      assert_equal native.explicit_begin(values), measured.explicit_begin(values)
      assert_equal native.block_ensure(values), measured.block_ensure(values)
      contexts = inventory[:decisions].to_h { |decision| [decision[:id], decision[:context]] }
      recorded = evidence.snapshot[:vectors].map { |vector| contexts[vector[:decision_id]] }.compact
      assert_includes recorded, "iteration"
      assert_includes recorded, "rescue"
      iteration = inventory[:decisions].find { |decision| decision[:context] == "iteration" }
      exception = inventory[:decisions].find { |decision| decision[:context] == "rescue" }
      vectors = evidence.snapshot[:vectors]
      assert_equal [false, true], vectors.find { |vector| vector[:decision_id] == iteration[:id] }[:values]
      exception_vectors = vectors.select { |vector| vector[:decision_id] == exception[:id] }.map { |vector| vector[:values] }
      assert_includes exception_vectors, [true, nil, nil]
      assert_includes exception_vectors, [false, true, nil]
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
  end

  def test_block_parameters_remain_before_instrumented_body
    source = "def self.exercise(values); values.filter_map do |value, index| Integer(value) + index rescue nil end; end\n"
    result = rewrite(source)

    assert_empty result[:diagnostics]
    assert_empty Prism.parse(result[:bytes]).errors
  end

  def test_empty_implicit_rescue_and_ensure_bodies_rewrite
    source = <<~RUBY
      def self.exercise(values)
        values.filter_map do |value|
        rescue StandardError
        end
        values.filter_map do |value|
        ensure
        end
      end
    RUBY
    result = rewrite(source)

    assert_empty result[:diagnostics]
    assert_empty Prism.parse(result[:bytes]).errors
  end

  private

  def rewrite(source)
    Dir.mktmpdir("branchproof-iteration-rescue") do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      return Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
    end
  end
end
