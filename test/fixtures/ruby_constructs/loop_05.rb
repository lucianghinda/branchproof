# frozen_string_literal: true

# LOOP-05: Post-test while always enters once
def example(limit)
  count = 0
  begin
    count += 1
  end while count < limit
  count
end
