# frozen_string_literal: true

# VAL-04: Method call result used as a condition
def lookup(value)
  value
end

def example(value)
  if lookup(value)
    "yes"
  else
    "no"
  end
end
