# frozen_string_literal: true

# FLOW-10: Yield requires a block and honors its transfers
def yield_value
  yield 3
end

def example(mode)
  return yield_value if mode == 'missing'
  yield_value do |value|
    break 'stopped' if mode == 'break'
    raise IOError if mode == 'raise'
    value * 2
  end
end
