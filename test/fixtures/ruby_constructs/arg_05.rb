# frozen_string_literal: true

# ARG-05: Decision inside a default
def example(ready, value = (ready ? "fast" : "slow"))
  value
end
