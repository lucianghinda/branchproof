# frozen_string_literal: true

def allowed?(paid, suspended)
  if paid && !suspended
    :allowed
  else
    :denied
  end
end
