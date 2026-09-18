# frozen_string_literal: true

# LOG-10: Standalone logic selects a returned value
def example(existing, fallback)
  value = existing || fallback
  value
end
