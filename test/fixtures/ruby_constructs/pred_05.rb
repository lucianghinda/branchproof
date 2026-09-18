# frozen_string_literal: true

# PRED-05: Nil and Boolean predicates
def example(value)
  [value.nil?, value == true, value == false]
end
