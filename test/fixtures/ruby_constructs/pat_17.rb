# frozen_string_literal: true

# PAT-17: Exact hash key pattern
def example(value)
  value.transform_keys(&:to_sym) in {name:, **nil}
end
