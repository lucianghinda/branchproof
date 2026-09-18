# frozen_string_literal: true

# EXC-08: Ensure runs during normal completion and unwinding
def example(mode)
  events = []
  begin
    1.times do
      begin
        return events if mode == 'return'
        break if mode == 'break'
        raise IOError if mode == 'exception'
        events << 'body'
      ensure
        events << 'cleanup'
      end
    end
  rescue IOError
    events << 'rescued'
  end
  events
end
