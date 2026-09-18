# frozen_string_literal: true

# LOOP-04: Modifier until tests before entering
def example(limit)
  count = 0
  count += 1 until count >= limit
  count
end
