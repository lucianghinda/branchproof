# frozen_string_literal: true

# PRED-15: Eager Boolean operators
def example(left, right)
  [left & right, left | right, left ^ right]
end
