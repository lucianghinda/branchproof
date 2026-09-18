# frozen_string_literal: true

# API-04: Prefix selection
def example(values)
  [values.take_while { |value| value > 0 }, values.drop_while { |value| value > 0 }]
end
