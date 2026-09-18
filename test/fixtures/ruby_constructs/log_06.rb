# frozen_string_literal: true

# LOG-06: Low-precedence not uses negation behavior
class CustomNegation
  def !
    "custom"
  end
end

def example(value, custom = false)
  value = CustomNegation.new if custom
  not value
end
