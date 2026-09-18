# frozen_string_literal: true

require "test_helper"
require "branchproof/instrumenter"
require_relative "support/ruby_constructs"

class TestInstrumenterEnclosures < Minitest::Test
  class Probe < Branchproof::Instrumenter
    attr_reader :comparisons

    def initialize
      super
      @comparisons = 0
    end

    def enclosures(decisions)
      send(:build_enclosures, decisions)
    end

    private

    def encloses_decision?(outer, inner)
      @comparisons += 1
      super
    end
  end

  def test_sweep_matches_quadratic_result_for_all_construct_inventories
    RubyConstructs.entries.each do |entry|
      decisions = RubyConstructs.inventory(entry.fetch("id")).fetch(:decisions)
      assert_equal quadratic(decisions), Probe.new.enclosures(decisions), entry.fetch("id")
    end
  end

  def test_sweep_handles_crossing_equal_and_distinct_equal_range_records
    decisions = [
      decision(0, 20, :boolean),
      decision(2, 4, :boolean),
      decision(5, 20, :boolean),
      decision(0, 20, :multiway),
      decision(0, 20, :boolean)
    ]

    assert_equal quadratic(decisions), Probe.new.enclosures(decisions)
  end

  def test_disjoint_decisions_do_not_trigger_quadratic_comparisons
    decisions = 1_000.times.map { |index| decision(index * 3, 1, :boolean) }
    probe = Probe.new

    probe.enclosures(decisions)

    assert_operator probe.comparisons, :<, decisions.length * 10
  end

  private

  def decision(start, length, kind)
    @decision_id = (@decision_id || 0) + 1
    { id: @decision_id, byte_start: start, byte_length: length, kind: kind.to_s }
  end

  def quadratic(decisions)
    encloses = {}.compare_by_identity
    enclosed = {}.compare_by_identity
    decisions.each do |outer|
      contained = decisions.select do |inner|
        outer != inner && contains?(outer, inner) &&
          (outer[:byte_start] != inner[:byte_start] || outer[:byte_length] != inner[:byte_length] ||
           (outer[:kind] == "boolean" && inner[:kind] != "boolean"))
      end
      encloses[outer] = contained
      contained.each { |inner| enclosed[inner] = true }
    end
    [encloses, enclosed]
  end

  def contains?(outer, inner)
    inner[:byte_start] >= outer[:byte_start] &&
      inner[:byte_start] + inner[:byte_length] <= outer[:byte_start] + outer[:byte_length]
  end
end
