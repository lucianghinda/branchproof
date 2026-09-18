# frozen_string_literal: true

# EXC-07: Else runs only after normal completion
def example(fail_body)
  begin
    raise ArgumentError if fail_body
    'body'
  rescue ArgumentError
    'rescue'
  else
    'else'
  end
end
