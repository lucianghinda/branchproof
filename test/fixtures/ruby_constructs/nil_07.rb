# frozen_string_literal: true

# NIL-07: Safe arithmetic and conditional assignment
Person = Struct.new(:count, :name)

def example(present, name)
  receiver = present ? Person.new(1, name) : nil
  trace = []
  receiver&.count += 1
  receiver&.name ||= (trace << "build"; "Ada")
  [receiver&.count, receiver&.name, trace]
end
