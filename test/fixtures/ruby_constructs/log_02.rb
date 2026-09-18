# frozen_string_literal: true

# LOG-02: Short-circuit disjunction
def example(left, right)
  trace = []
  value = left || (trace << "right"; right)
  [value, trace]
end
