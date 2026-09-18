# frozen_string_literal: true

# ASGN-01: Conditional ||= assignment
def example(value)
  value ||= "new"
  value
end
