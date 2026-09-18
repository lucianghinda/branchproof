# frozen_string_literal: true

# API-08: Lazy predicates run only for demanded elements
def example(values, count)
  seen = []
  selected = values.lazy.select do |value|
    seen << value
    value > 0
  end.first(count)
  [selected, seen]
end
