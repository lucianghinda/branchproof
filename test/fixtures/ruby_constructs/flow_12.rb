# frozen_string_literal: true

# FLOW-12: Process termination is isolated in a subprocess
def example(mode)
  case mode
  when 'exit' then exit 7
  when 'abort' then abort 'stopped'
  when 'immediate' then exit! 7
  end
end
