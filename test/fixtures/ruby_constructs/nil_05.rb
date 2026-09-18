# frozen_string_literal: true

# NIL-05: Safe setter skips its right-hand side
Person = Struct.new(:name)

def example(present)
  receiver = present ? Person.new : nil
  trace = []
  receiver&.name = (trace << "rhs"; "Ada")
  [receiver&.name, trace]
end
