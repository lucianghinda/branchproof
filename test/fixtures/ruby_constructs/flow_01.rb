# frozen_string_literal: true

# FLOW-01: Return exits before later expressions
def example(bare)
  return if bare
  return 'returned'
  'unreachable'
end
