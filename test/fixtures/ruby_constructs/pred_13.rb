# frozen_string_literal: true

# PRED-13: Regexp capture state
def example(text)
  /\A(?<letter>a)\z/ =~ text
  [letter, $1]
end
