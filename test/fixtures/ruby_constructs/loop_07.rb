# frozen_string_literal: true

# LOOP-07: For shares its surrounding local scope
def example(items)
  total = 0
  item = nil
  for item in items
    total += item
  end
  [total, item]
end
