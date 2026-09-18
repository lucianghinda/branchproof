# frozen_string_literal: true

# ASGN-03: Previously uninitialized local target
def example(initialize_local, initial)
  value = initial if initialize_local
  value ||= "new"
  value
end
