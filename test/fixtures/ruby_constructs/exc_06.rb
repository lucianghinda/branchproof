# frozen_string_literal: true

# EXC-06: Dynamic splatted rescue classes
def example(mode)
  error_types = case mode
                when 'empty' then []
                when 'invalid' then [42]
                else [ArgumentError, IOError]
                end
  begin
    raise IOError
  rescue *error_types
    'handled'
  end
end
