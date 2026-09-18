# frozen_string_literal: true

# VAL-05: Assignment used as a condition
def example(input)
  selected = if (value = input)
    "yes"
  else
    "no"
  end
  [selected, value]
end
