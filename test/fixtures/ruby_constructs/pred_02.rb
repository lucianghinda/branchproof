# frozen_string_literal: true

# PRED-02: Ordering and boundaries
def example(value)
  [value < 1, value <= 1, value > 1, value >= 1, value.between?(1, 2)]
end
