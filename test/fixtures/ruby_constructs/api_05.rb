# frozen_string_literal: true

# API-05: Partition by a predicate
def example(values)
  values.partition { |value| value.even? }
end
