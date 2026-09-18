# frozen_string_literal: true

# VAL-02: Truthy non-Boolean values
def example
  [0, "", [], {}, Object.new].map { |value| value ? true : false }
end
