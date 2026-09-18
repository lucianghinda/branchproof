# frozen_string_literal: true

# PAT-13: Find an integer anywhere in an array
def example(value)
  case value
  in [*, Integer => number, *] then number
  else nil
  end
end
