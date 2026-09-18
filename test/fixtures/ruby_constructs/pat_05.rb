# frozen_string_literal: true

# PAT-05: if pattern guard
def example(value, allowed)
  case value
  in [Integer] if allowed then "match"
  else "fallback"
  end
end
