# frozen_string_literal: true

# VAL-03: Variable reads in conditions
VALUE = "constant"
module Values
  VALUE = "qualified"
end

class VariableReads
  def self.check(value)
    local = value
    @instance = value
    @@class_value = value
    $construct_value = value
    [local ? true : false, @instance ? true : false, @@class_value ? true : false,
     $construct_value ? true : false, VALUE ? true : false,
     Values::VALUE ? true : false, @uninitialized ? true : false]
  end
end

def example(value)
  VariableReads.check(value)
end
