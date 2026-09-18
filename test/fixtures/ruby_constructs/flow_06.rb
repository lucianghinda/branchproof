# frozen_string_literal: true

# FLOW-06: Control transfer on a logical right-hand side
def example(valid, values)
  valid or return
  selected = []
  values.each do |value|
    value < 0 && break
    selected << value
  end
  selected
end
