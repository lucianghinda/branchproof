# frozen_string_literal: true

# CASE-03: Multiple candidates are evaluated in order
def example(value)
  trace = []
  result = case value
  when (trace << "first"; 1), (trace << "second"; 2)
    "hit"
  else
    "miss"
  end
  [result, trace]
end
