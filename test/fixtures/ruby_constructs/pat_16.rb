# frozen_string_literal: true

# PAT-16: Hash rest capture
def example(value)
  value.transform_keys(&:to_sym) => {name:, **rest}
  [name, rest.transform_keys(&:to_s)]
end
