# frozen_string_literal: true

# FLOW-05: Guarded return, break, and next
def example(valid, values)
  return unless valid
  selected = []
  values.each do |value|
    break if value < 0
    next if value == 0
    selected << value
  end
  selected
end
