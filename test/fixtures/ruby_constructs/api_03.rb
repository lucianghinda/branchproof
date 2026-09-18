# frozen_string_literal: true

# API-03: Search stops at the first matching element
def example(values)
  [values.find { |value| value > 0 }, values.find_index { |value| value > 0 }]
end
