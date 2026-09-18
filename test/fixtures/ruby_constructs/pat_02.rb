# frozen_string_literal: true

# PAT-02: Pattern arms without a fallback
def example(value)
  case value
  in Integer then "integer"
  end
end
