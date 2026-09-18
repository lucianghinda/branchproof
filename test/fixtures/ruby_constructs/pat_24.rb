# frozen_string_literal: true

# PAT-24: Compound pattern guard short-circuits
def example(age, permitted)
  trace = []
  result = case {age: age}
  in {age: Integer => years} if years >= 18 && (trace << "permission"; permitted)
    "adult"
  else
    "other"
  end
  [result, trace]
end
