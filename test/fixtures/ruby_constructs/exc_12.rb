# frozen_string_literal: true

# EXC-12: Raise, fail, explicit exception, and bare re-raise
def example(mode)
  case mode
  when 'raise' then raise ArgumentError, 'new error'
  when 'fail' then fail IOError, 'failed'
  when 'explicit' then raise RangeError.new('explicit')
  else
    begin
      raise TypeError, 'original'
    rescue TypeError
      raise
    end
  end
end
