# frozen_string_literal: true

# EXC-14: Nested handlers and cleanup order
def example(mode)
  events = []
  begin
    begin
      raise ArgumentError if mode == 'inner'
      raise IOError if mode == 'outer'
      raise RangeError if mode == 'escape'
    rescue ArgumentError
      events << 'inner'
    ensure
      events << 'inner cleanup'
    end
  rescue IOError
    events << 'outer'
  ensure
    events << 'outer cleanup'
  end
  events
end
