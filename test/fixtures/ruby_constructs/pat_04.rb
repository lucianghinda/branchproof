# frozen_string_literal: true

# PAT-04: Required match binds a value
def example(value)
  value => [Integer => number]
  number
end
