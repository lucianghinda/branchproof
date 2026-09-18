# frozen_string_literal: true

# LOG-03: Low-precedence and preserves assignment to the left operand
def example(left, right)
  trace = []
  result = left and trace << right
  [result, trace]
end
