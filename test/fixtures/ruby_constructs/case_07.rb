# frozen_string_literal: true

# CASE-07: Subjectless candidate list short-circuits
def example(first, second)
  trace = []
  result = case
  when (trace << "first"; first), (trace << "second"; second)
    "hit"
  end
  [result, trace]
end
