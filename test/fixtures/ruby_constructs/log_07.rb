# frozen_string_literal: true

# LOG-07: Double negation
class CustomNegation
  def !
    "custom"
  end
end

def example(value, custom = false)
  value = CustomNegation.new if custom
  !!value
end
