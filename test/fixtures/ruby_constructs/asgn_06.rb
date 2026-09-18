# frozen_string_literal: true

# ASGN-06: Attribute conditional assignment
Box = Struct.new(:value)

def example(initial)
  receiver = Box.new(initial)
  trace = []
  receiver.value ||= (trace << "build"; "new")
  [receiver.value, trace]
end
