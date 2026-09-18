# frozen_string_literal: true

# NIL-01: Safe method call gates only nil
def example(receiver)
  receiver&.to_s
end
