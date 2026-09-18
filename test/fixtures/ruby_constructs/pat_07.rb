# frozen_string_literal: true

# PAT-07: Value patterns use case equality
def example(value)
  case value
  in Integer then "integer"
  in nil then "nil"
  in /abc/ then "text"
  else "other"
  end
end
