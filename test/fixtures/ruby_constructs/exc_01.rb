# frozen_string_literal: true

# EXC-01: Protected region with handled and escaping exceptions
def example(mode)
  begin
    raise ArgumentError if mode == 'argument'
    raise IOError if mode == 'io'
    'ok'
  rescue ArgumentError
    'handled'
  end
end
