# frozen_string_literal: true

# FLOW-08: Proc return targets its enclosing method
def escaped_return
  proc { return 'too late' }
end

def example(escaped)
  return escaped_return.call if escaped
  operation = proc { return 'returned' }
  operation.call
  'unreachable'
end
