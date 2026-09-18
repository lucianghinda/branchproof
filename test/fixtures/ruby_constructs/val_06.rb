# frozen_string_literal: true

# VAL-06: Compound expression uses its last result
def example(value)
  trace = []
  selected = if begin
    trace << "first"
    value
  end
    "yes"
  else
    "no"
  end
  [selected, trace]
end
