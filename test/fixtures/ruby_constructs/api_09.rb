# frozen_string_literal: true

# API-09: Custom block conversion
class PositivePredicate
  def to_proc
    ->(value) { value > 0 }
  end
end

def example(values)
  values.map(&PositivePredicate.new)
end
