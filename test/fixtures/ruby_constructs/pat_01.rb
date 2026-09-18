# frozen_string_literal: true

# PAT-01: Pattern arm with explicit fallback
def example(value)
  case value
  in Integer then "integer"
  else "other"
  end
end
