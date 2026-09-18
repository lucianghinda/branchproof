# frozen_string_literal: true

# PAT-20: As-pattern captures a matched value
def example(value)
  case value
  in Integer => number then number
  else nil
  end
end
