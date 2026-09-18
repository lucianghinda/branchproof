# frozen_string_literal: true

# PAT-14: Hash subset pattern
def example(value)
  value.transform_keys(&:to_sym) in {name: String}
end
