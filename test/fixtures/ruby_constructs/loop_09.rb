# frozen_string_literal: true

# LOOP-09: Nested break exits only the inner loop
def example(count)
  values = []
  count.times do |outer|
    2.times do |inner|
      break if inner == 1
      values << [outer, inner]
    end
  end
  values
end
