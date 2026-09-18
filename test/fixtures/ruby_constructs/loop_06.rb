# frozen_string_literal: true

# LOOP-06: Post-test until always enters once
def example(limit)
  count = 0
  begin
    count += 1
  end until count >= limit
  count
end
