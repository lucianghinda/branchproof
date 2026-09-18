# frozen_string_literal: true

# PAT-23: Custom array deconstruction
class Deconstructable
  def initialize(mode)
    @mode = mode
  end

  def deconstruct
    raise "deconstruction failed" if @mode == "raise"
    @mode == "invalid" ? 1 : [2]
  end
end

def example(mode)
  value = mode == "absent" ? Object.new : Deconstructable.new(mode)
  value in [Integer]
end
