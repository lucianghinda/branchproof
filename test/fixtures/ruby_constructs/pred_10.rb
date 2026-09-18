# frozen_string_literal: true

# PRED-10: Range membership
def example(value)
  range = 1..3
  [range.cover?(value), range.include?(value), range === value]
end
