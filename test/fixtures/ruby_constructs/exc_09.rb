# frozen_string_literal: true

# EXC-09: Modifier rescue supplies a fallback
def example(value)
  Integer(value) rescue 0
end
