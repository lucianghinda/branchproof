# frozen_string_literal: true

# CASE-05: Case without else returns nil when unmatched
def example(value)
  case value
  when 1
    "hit"
  end
end
