# frozen_string_literal: true

# PAT-12: Array rest capture
def example(value)
  case value
  in [head, *tail] then [head, tail]
  else nil
  end
end
