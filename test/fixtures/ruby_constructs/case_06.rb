# frozen_string_literal: true

# CASE-06: Subjectless case tests truthiness
def example(first, second)
  case
  when first
    "first"
  when second
    "second"
  else
    "neither"
  end
end
