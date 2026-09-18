# frozen_string_literal: true

# EXC-03: Typed rescue binds the exception
def example(matches)
  begin
    raise(matches ? IOError : ArgumentError, 'broken input')
  rescue IOError => error
    error.message
  end
end
