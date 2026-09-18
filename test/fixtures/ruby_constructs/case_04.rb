# frozen_string_literal: true

# CASE-04: Splatted candidates mixed with an ordinary candidate
def example(value, matchers)
  case value
  when 0, *matchers
    "hit"
  else
    "miss"
  end
end
