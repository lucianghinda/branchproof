# frozen_string_literal: true

module Branchproof
  # Records which operand of a fallback chain supplied the value. Only truthy
  # operands are recorded; `||` itself decides whether evaluation continues.
  module FallbackRuntime
    def fallback_operand(decision_id, index, implicit, value)
      return value unless value

      implicit ? flow_path(decision_id, index) : flow_select(decision_id, index)
      value
    end
  end
end
