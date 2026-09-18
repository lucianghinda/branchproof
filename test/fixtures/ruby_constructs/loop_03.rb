# frozen_string_literal: true

# LOOP-03: Modifier while tests before entering
def example(limit)
  count = 0
  count += 1 while count < limit
  count
end
