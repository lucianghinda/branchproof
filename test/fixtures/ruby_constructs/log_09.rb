# frozen_string_literal: true

# LOG-09: Repeated calls remain separate evaluations
def example(values)
  trace = []
  check = -> { value = values.shift; trace << value; value }
  result = check.call && check.call
  [result, trace]
end
