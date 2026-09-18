# frozen_string_literal: true

# LOG-01: Short-circuit conjunction
def example(left, right)
  trace = []
  value = left && (trace << "right"; right)
  [value, trace]
end
