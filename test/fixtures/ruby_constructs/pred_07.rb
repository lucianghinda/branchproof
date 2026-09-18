# frozen_string_literal: true

# PRED-07: Membership and key existence
def example(value)
  [[1, 2].include?(value), { "one" => 1 }.key?(value)]
end
