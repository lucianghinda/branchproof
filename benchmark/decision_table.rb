# frozen_string_literal: true

require "benchmark"
require "branchproof"

DT = Branchproof::DecisionTable

def atom(index) = { type: :atom, index: index }
def and_node(left, right) = { type: :and, left: left, right: right }
def or_node(left, right) = { type: :or, left: left, right: right }

def alternating_tree(count)
  (1...count).reduce(atom(0)) do |tree, index|
    index.even? ? and_node(tree, atom(index)) : or_node(tree, atom(index))
  end
end

def trace(node, assignment, values)
  case node[:type]
  when :atom
    values[node[:index]] = assignment[node[:index]]
    assignment[node[:index]]
  when :and
    trace(node[:left], assignment, values) && trace(node[:right], assignment, values)
  when :or
    trace(node[:left], assignment, values) || trace(node[:right], assignment, values)
  end
end

def vectors(count, tree)
  items = (0...(1 << count)).map do |mask|
    assignment = (0...count).to_h { |index| [index, mask.anybits?(1 << index)] }
    values = Array.new(count)
    outcome = trace(tree, assignment, values)
    [values, outcome]
  end
  items.uniq.each_with_index.map do |(values, outcome), index|
    { id: "v#{index}", values: values, outcome: outcome }
  end
end

def decision(count, tree)
  { id: "benchmark-#{count}", tree: tree,
    conditions: (0...count).map { |index| { id: "c#{index}", index: index } } }
end

def measure
  before = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  [elapsed, GC.stat(:total_allocated_objects) - before, result]
end

[3, 12, 16].each do |count|
  tree = alternating_tree(count)
  inventory = decision(count, tree)
  observations = vectors(count, tree)
  limits = { max_conditions_for_decision_table: count, decision_table_rules_per_decision: 4096 }
  fast = measure { DT.build(decision: inventory, vectors: observations, limits: limits) }
  rules = fast[2][:rules]
  baseline = measure do
    rules.map do |rule|
      observations.select { |vector| DT.matches?(rule, vector) }
    end
  end
  output = "conditions=%<count>d unique_vectors=%<vectors>d rules=%<rules>d fast=%<time>.4fs/%<alloc>d " \
           "baseline=%<base_time>.4fs/%<base_alloc>d"
  puts format(output, count: count, vectors: observations.length, rules: rules.length,
                      time: fast[0], alloc: fast[1], base_time: baseline[0], base_alloc: baseline[1])
end
