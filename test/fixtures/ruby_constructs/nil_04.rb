# frozen_string_literal: true

# NIL-04: Safe navigation skips arguments and block
def example(receiver)
  trace = []
  result = receiver&.zip((trace << "argument"; ["argument"])) { |pair| trace << "block"; pair }
  [result, trace]
end
