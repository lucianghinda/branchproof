# frozen_string_literal: true

module Branchproof
  # A value-context `||` chain that ends in an always-truthy literal returns
  # the first truthy operand and is never false. It is inventoried as
  # alternatives (which operand supplied the value), not as a Boolean decision.
  module FallbackSyntax
    # A jump never supplies a value, so it cannot be a fallback operand.
    JUMP_NODES = [Prism::ReturnNode, Prism::BreakNode, Prism::NextNode, Prism::RedoNode,
                  Prism::RetryNode].freeze
    private_constant :JUMP_NODES

    private

    def fallback_chain?(node)
      return false unless symbolic_or?(node)

      operands = fallback_operands(node)
      last = operands.last
      literal_truth(last) == true && !last.is_a?(Prism::TrueNode) &&
        operands[0...-1].none? do |operand|
          logical_operand?(operand) || jump_operand?(operand) || contextual_operand?(operand)
        end
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

    def jump_operand?(operand)
      tail = tail_statement(operand)
      JUMP_NODES.any? { |type| tail.is_a?(type) }
    end

    def contextual_operand?(operand)
      operand = unwrap_predicate(operand)
      operand.is_a?(Prism::MatchLastLineNode) || operand.is_a?(Prism::InterpolatedMatchLastLineNode) ||
        operand.is_a?(Prism::FlipFlopNode)
    end

    # A `(...)` or `begin...end` operand evaluates to its last statement, so a
    # trailing jump there ends the operand too. Only the last statement
    # matters: an earlier jump would already end evaluation inside its own
    # construct (such as `if`), which is fine as an operand.
    def tail_statement(node)
      loop do
        body = case node
               when Prism::ParenthesesNode then node.body&.body
               when Prism::BeginNode then node.statements&.body
               end
        return node if body.nil? || body.empty?

        node = body.last
      end
    end
  end
end
