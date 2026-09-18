# frozen_string_literal: true

# FLOW-11: Super delegates arguments and blocks
class ExampleParent
  def implicit(value = 'default')
    [value, block_given? ? yield(value) : nil]
  end
  alias empty implicit
  alias explicit implicit
  alias forwarded implicit
end

class ExampleChild < ExampleParent
  def implicit(value)
    super
  end

  def empty(value)
    super()
  end

  def explicit(value)
    super('changed')
  end

  def forwarded(...)
    super(...)
  end
end

def example(mode, value)
  ExampleChild.new.public_send(mode, value) { |item| item.upcase }
end
