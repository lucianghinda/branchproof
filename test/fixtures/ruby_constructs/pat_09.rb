# frozen_string_literal: true

# PAT-09: Pin an existing value
def example(value, expected)
  value in ^expected
end
