# frozen_string_literal: true

# API-02: Filtering and transforming
def example(values)
  selected = values.select { |value| value > 0 }
  rejected = values.reject { |value| value > 0 }
  mapped = values.filter_map { |value| value * 2 if value > 0 }
  [selected, rejected, mapped]
end
