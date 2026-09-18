# frozen_string_literal: true

# ARG-03: Dependent defaults
def example(first = 2, second = first + 1)
  [first, second]
end
