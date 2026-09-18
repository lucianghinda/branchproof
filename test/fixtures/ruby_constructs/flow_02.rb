# frozen_string_literal: true

# FLOW-02: Break controls the yielding expression result
def example(bare)
  loop do
    break if bare
    break 'stopped'
  end
end
