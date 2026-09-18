# frozen_string_literal: true

# EXC-04: Multiple classes select one handler
def example(io)
  begin
    raise(io ? IOError : ArgumentError)
  rescue IOError, ArgumentError
    'handled'
  end
end
