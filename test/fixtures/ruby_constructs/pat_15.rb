# frozen_string_literal: true

# PAT-15: Hash shorthand capture
def example(value)
  value.transform_keys(&:to_sym) => {name:}
  name
end
