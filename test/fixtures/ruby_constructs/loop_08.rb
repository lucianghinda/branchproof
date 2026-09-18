# frozen_string_literal: true

# LOOP-08: Iterator-defined repetition
def example(count)
  values = []
  count.times { |index| values << index }
  values
end
