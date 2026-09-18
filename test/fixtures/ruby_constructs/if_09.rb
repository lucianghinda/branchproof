# frozen_string_literal: true

# IF-09: Nested conditional
def example(first, second)
  first ? (second ? "both" : "first") : "neither"
end
