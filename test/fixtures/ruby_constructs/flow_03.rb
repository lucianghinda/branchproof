# frozen_string_literal: true

# FLOW-03: Next skips remaining block expressions and supplies a value
def example(values)
  values.map do |value|
    next if value == 0
    next 'negative' if value < 0
    value * 2
  end
end
