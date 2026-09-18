# frozen_string_literal: true

# EXC-11: Retry restarts the protected body with a bounded budget
def example(failures)
  attempts = 0
  begin
    attempts += 1
    raise IOError if attempts <= failures
    attempts
  rescue IOError
    retry if attempts < 3
    raise
  end
end
