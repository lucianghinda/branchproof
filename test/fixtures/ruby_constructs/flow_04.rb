# frozen_string_literal: true

# FLOW-04: Redo repeats the current iteration without advancing
def example(repeat)
  values = []
  2.times do |index|
    values << index
    if repeat
      repeat = false
      redo
    end
  end
  values
end
