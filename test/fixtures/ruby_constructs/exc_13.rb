# frozen_string_literal: true

# EXC-13: Handler, else, and ensure exceptions reach the outer rescue
def example(mode)
  begin
    begin
      raise ArgumentError if mode == 'handler'
    rescue ArgumentError
      raise IOError, 'handler'
    else
      raise IOError, 'else' if mode == 'else'
    ensure
      raise IOError, 'ensure' if mode == 'ensure'
    end
  rescue IOError => error
    error.message
  end
end
