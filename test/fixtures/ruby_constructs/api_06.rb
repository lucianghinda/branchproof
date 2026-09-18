# frozen_string_literal: true

# API-06: Conditional count
def example(values)
  values.count { |value| value > 0 }
end
