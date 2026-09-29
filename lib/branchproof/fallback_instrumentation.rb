# frozen_string_literal: true

module Branchproof
  # Wraps each fallback operand so the runtime sees the operand's own value.
  # `||` still short-circuits, so later operands are never evaluated early.
  module FallbackInstrumentation
    private

    def render_flow(bytes, decision, nested, encloses)
      metadata = decision.fetch(:instrumentation)
      return super unless metadata[:type] == "fallback"

      identifier = decision[:id].inspect
      implicit = decision[:kind] == "implicit"
      replacements = metadata.fetch(:operands).each_with_index.map do |operand, index|
        flow_replacement(bytes, operand, nested, encloses) do |expression|
          "#{self.class::RUNTIME}.fallback_operand(#{identifier}, #{index}, #{implicit}, (#{expression}))"
        end
      end
      flow_frame(decision[:id], flow_fragments(bytes, decision, nested, replacements, encloses))
    end
  end
end
