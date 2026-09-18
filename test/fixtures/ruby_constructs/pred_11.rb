# frozen_string_literal: true

# PRED-11: Regexp index and Boolean results
def example(text)
  [/a/ =~ text, /a/ !~ text, /a/.match?(text)]
end
