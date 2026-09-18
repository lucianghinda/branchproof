# frozen_string_literal: true

# LOOP-10: User-defined each yields while its own inner each frame is active
class Bag
  include Enumerable

  def initialize(items)
    @items = items
  end

  def each
    @items.each { |item| yield item }
  end
end

def example(items)
  bag = Bag.new(items)
  seen = []
  bag.each { |item| seen << item }
  seen
end
