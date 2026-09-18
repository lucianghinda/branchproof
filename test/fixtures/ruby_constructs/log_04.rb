# frozen_string_literal: true

# LOG-04: Low-precedence or preserves assignment to the left operand
def example(left, right)
  trace = []
  result = left or trace << right
  [result, trace]
end
