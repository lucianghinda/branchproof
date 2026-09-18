# frozen_string_literal: true

# VAL-01: Literal true, false, and nil
def example
  [if true then "yes" end, if false then "yes" end, if nil then "yes" end]
end
