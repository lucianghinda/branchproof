# frozen_string_literal: true

# Independent exhaustive oracle for the bounded analytical model. It evaluates
# assignments directly, then checks whether a single target flip can alter the
# decision while preserving the observed short-circuit trace.
module BooleanOracle
  module_function

  def evaluate(tree, assignment)
    trace = []
    result = visit(tree, assignment, trace)
    [result, trace]
  end

  def effective?(tree, observation, target)
    outcome, trace = observation
    return false unless trace.any? { |index, _| index == target }

    leaves = tree_leaves(tree)
    [false, true].repeated_permutation(leaves.length).any? do |values|
      assignment = leaves.zip(values).to_h
      result, candidate_trace = evaluate(tree, assignment)
      next false unless candidate_trace == trace

      flipped = assignment.merge(target => !assignment.fetch(target))
      flipped_result, = evaluate(tree, flipped)
      result != flipped_result && result == outcome
    end
  end

  def visit(node, assignment, trace)
    if node[:type].to_sym == :atom
      value = assignment.fetch(node[:index]) == true
      trace << [node[:index], value]
      return value
    end
    left = visit(node[:left], assignment, trace)
    return left if node[:type].to_sym == :and && !left
    return left if node[:type].to_sym == :or && left

    visit(node[:right], assignment, trace)
  end

  def tree_leaves(node)
    return [node[:index]] if node[:type].to_sym == :atom

    tree_leaves(node[:left]) + tree_leaves(node[:right])
  end
end
