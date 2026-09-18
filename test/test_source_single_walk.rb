# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestSourceSingleWalk < Minitest::Test
  class CountingSource < Branchproof::Source
    attr_reader :walk_count, :node_ids, :top_level_walks

    def initialize(**kwargs)
      super
      @walk_count = 0
      @node_ids = {}.compare_by_identity
      @top_level_walks = 0
    end

    private

    def walk_skipping_defined_operands(node, &)
      return super unless node.is_a?(Prism::ProgramNode)

      @top_level_walks += 1
      super do |visited|
        @walk_count += 1
        @node_ids[visited] = true
        yield visited
      end
    end
  end

  def test_value_candidates_are_classified_by_the_single_source_walk
    source = <<~RUBY
      def self.exercise(left, right, values)
        if left && right
          values[0] == values[1]
        end
      end
    RUBY

    Dir.mktmpdir("branchproof-single-walk") do |root|
      path = File.join(root, "fixture.rb")
      File.write(path, source)
      inventory = CountingSource.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      decisions = inventory.fetch(:decisions)
      counter = CountingSource.new(root: root, limits: Branchproof::Limits.default)
      counter.inventory(paths: [path])

      assert_equal 1, counter.top_level_walks
      assert_equal counter.node_ids.length, counter.walk_count
      assert_equal %w[if lookup lookup predicate].sort,
                   decisions.map { |decision| decision[:context] }.sort
      assert_equal decisions.map { |decision| decision[:id] }.uniq.length, decisions.length

      unit = inventory.fetch(:source_units).first
      program = Prism.parse(source).value
      non_values = decisions.reject { |decision| decision.dig(:instrumentation, :type) == "value" }
      range_pairs = non_values.flat_map do |decision|
        [[decision[:byte_start], decision[:byte_length]]] +
          Array(decision[:conditions]).map { |condition| condition.values_at(:byte_start, :byte_length) }
      end
      occupied = range_pairs.to_h do |start_offset, length|
        [(start_offset << 32) | length, true]
      end
      legacy_values = counter.send(:value_decisions_for, program, source, unit[:source_id],
                                   occupied_ranges: occupied)
      fused_values = decisions.select { |decision| decision.dig(:instrumentation, :type) == "value" }
      signature = ->(rows) { rows.map { |row| row.values_at(:context, :byte_start, :byte_length) } }
      assert_equal signature.call(legacy_values), signature.call(fused_values)
    end
  end

  def test_defined_operands_are_excluded_from_the_fused_value_walk
    source = <<~RUBY
      def self.exercise
        defined?(missing_method && (value[0] == value[1]))
      end
    RUBY

    Dir.mktmpdir("branchproof-single-walk-defined") do |root|
      path = File.join(root, "fixture.rb")
      File.write(path, source)
      inventory = CountingSource.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])

      assert_equal 1, inventory[:decisions].length
      assert_equal "defined", inventory[:decisions].first[:context]
      assert_equal "SUPPORTED", inventory[:decisions].first[:support_status]
    end
  end
end
