# frozen_string_literal: true

# PAT-06: unless pattern guard
def example(value, allowed)
  case value
  in [Integer] unless allowed then "match"
  else "fallback"
  end
end
