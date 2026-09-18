# frozen_string_literal: true

# CASE-02: First matching when clause wins
def example(value)
  case value
  when 1..3
    "small"
  when Integer
    "integer"
  else
    "other"
  end
end
