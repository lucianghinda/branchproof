# frozen_string_literal: true

# CASE-08: Case subject is evaluated once
def example(value)
  calls = 0
  load_value = -> { calls += 1; value }
  result = case load_value.call
  when 1
    "first"
  when 2
    "second"
  else
    "miss"
  end
  [result, calls]
end
