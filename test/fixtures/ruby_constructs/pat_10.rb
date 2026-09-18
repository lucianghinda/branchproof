# frozen_string_literal: true

# PAT-10: Pin a range expression
def example(value, lower, upper)
  value in ^(lower..upper)
end
