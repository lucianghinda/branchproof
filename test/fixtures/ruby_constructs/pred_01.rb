# frozen_string_literal: true

# PRED-01: Equality and identity
def example(left, right)
  [left == right, left != right, left.eql?(right), left.equal?(right)]
end
