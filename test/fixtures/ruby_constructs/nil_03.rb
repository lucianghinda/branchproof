# frozen_string_literal: true

# NIL-03: Ordinary call after safe navigation
def example(user)
  user&.[]("profile").length
end
