# frozen_string_literal: true

# ASGN-08: Nested conditional assignments
def example(a, b)
  trace = []
  a ||= (b &&= (trace << "build"; "new"))
  [a, b, trace]
end
