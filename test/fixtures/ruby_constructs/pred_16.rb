# frozen_string_literal: true

# PRED-16: Application predicate
def admin?(role)
  role == "admin"
end

def example(role)
  admin?(role)
end
