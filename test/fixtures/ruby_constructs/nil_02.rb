# frozen_string_literal: true

# NIL-02: Chained safe calls
def example(user)
  user&.[]("profile")&.[]("name")
end
