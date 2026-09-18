# frozen_string_literal: true

# PRED-03: Three-way comparison returns a value, not a Boolean
def example(left, right)
  left <=> right
end
