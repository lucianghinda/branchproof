# frozen_string_literal: true

# NIL-06: Safe indexing call
def example(receiver, key)
  receiver&.[](key)
end
