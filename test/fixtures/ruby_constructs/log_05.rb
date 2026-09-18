# frozen_string_literal: true

# LOG-05: Unary negation can be overridden
class CustomNegation
  def !
    "custom"
  end
end

def example(value, custom = false)
  value = CustomNegation.new if custom
  !value
end
