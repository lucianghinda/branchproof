# frozen_string_literal: true

# EXC-05: First matching rescue clause wins
def example(specific)
  begin
    raise(specific ? ArgumentError : RuntimeError)
  rescue ArgumentError
    'specific'
  rescue StandardError
    'general'
  end
end
