# frozen_string_literal: true

# CASE-01: Subjectful case
def example(value)
  case value
  when 1
    "hit"
  else
    "miss"
  end
end
