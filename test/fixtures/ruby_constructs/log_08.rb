# frozen_string_literal: true

# LOG-08: Nested logical expressions
def example(first, middle, last)
  trace = []
  value = first && ((trace << "middle"; middle) || (trace << "last"; last))
  [value, trace]
end
