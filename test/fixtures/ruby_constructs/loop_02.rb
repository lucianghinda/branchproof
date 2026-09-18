# frozen_string_literal: true

# LOOP-02: Pre-test until
def example(limit)
  count = 0
  until count >= limit
    count += 1
  end
  count
end
