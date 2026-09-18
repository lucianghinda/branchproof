# frozen_string_literal: true

# PAT-08: Capture and wildcard accept falsey values
def example(value)
  value => [name, _]
  name
end
