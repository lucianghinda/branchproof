# frozen_string_literal: true

module Branchproof
  # A value-context `||` chain that ends in an always-truthy literal returns
  # the first truthy operand and is never false. It is inventoried as
  # alternatives (which operand supplied the value), not as a Boolean decision.
  module FallbackSyntax
    private

    def fallback_chain?(node)
      return false unless symbolic_or?(node)

      operands = fallback_operands(node)
      last = operands.last
      literal_truth(last) == true && !last.is_a?(Prism::TrueNode) &&
        operands[0...-1].none? { |operand| logical_operand?(operand) }
    end

    # Only reached for OrNodes already gated by fallback_chain? in Source#decisions_for phase two.
    # rubocop:disable-next Metrics/AbcSize -- alternative/instrumentation assembly mirrors DecisionSyntax#flow_details.
    def flow_details(node, bytes, encoding)
      return super unless node.is_a?(Prism::OrNode)

      operands = fallback_operands(node)
      alternatives = operands.map do |operand|
        location = operand.location
        { expression: text_value(bytes.byteslice(location.start_offset, location.length), encoding),
          byte_start: location.start_offset, byte_length: location.length }
      end
      instrumentation = { type: "fallback", operands: operands.map { |operand| byte_range(operand.location) } }
      kind = operands.length == 2 ? "implicit" : "multiway"
      [kind, "fallback", alternatives, instrumentation, unsupported_reasons(node, bytes)]
    end

    # `a || b || c` parses as `(a || b) || c`, so the chain grows to the left.
    def fallback_operands(node)
      left = node.left
      (symbolic_or?(left) ? fallback_operands(left) : [left]) + [node.right]
    end

    def symbolic_or?(node)
      node.is_a?(Prism::OrNode) && node.operator_loc.slice == "||"
    end

    def logical_operand?(operand)
      operand = unwrap_predicate(operand)
      boolean_node?(operand) || unary_not?(operand)
    end
  end
end
