# frozen_string_literal: true

class FixtureDecisionService
  def choose(value)
    if value && value > 1
      :large
    else
      :small
    end
  end
end
