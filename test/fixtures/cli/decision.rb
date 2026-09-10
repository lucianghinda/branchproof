# frozen_string_literal: true

module CliFixture
  module_function

  def decide(left, right)
    if left && right
      :yes
    else
      :no
    end
  end
end
