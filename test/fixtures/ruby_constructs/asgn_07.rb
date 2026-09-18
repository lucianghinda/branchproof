# frozen_string_literal: true

# ASGN-07: Indexed conditional assignment
def example(initial)
  receiver = [initial]
  trace = []
  receiver[(trace << "index"; 0)] &&= (trace << "update"; "new")
  [receiver, trace]
end
