# frozen_string_literal: true

# FLIP-01: Flip-flop retains state between evaluations
def example(values)
  selected = []
  values.each do |value|
    if (value == 1)..(value == 1)
      selected << value
    end
  end
  selected
end
