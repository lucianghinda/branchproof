# frozen_string_literal: true

# EXC-10: Method body has implicit exception protection
def example(fail_body)
  events = []
  raise ArgumentError if fail_body
rescue ArgumentError
  events << 'rescue'
else
  events << 'else'
ensure
  events << 'ensure'
end
