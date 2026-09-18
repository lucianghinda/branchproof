# frozen_string_literal: true

# ARG-04: Lambda parameter default
def example(arguments)
  callable = ->(value = "default") { value }
  callable.call(*arguments)
end
