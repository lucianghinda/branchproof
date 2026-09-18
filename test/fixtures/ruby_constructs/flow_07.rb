# frozen_string_literal: true

# FLOW-07: Catch handles the nearest matching throw tag
def example(mode)
  catch(:done) do
    throw :missing if mode == 'unmatched'
    throw :done, 'thrown' if mode == 'matching'
    if mode == 'nearest'
      inner = catch(:done) { throw :done, 'inner' }
      [inner, 'outer continued']
    else
      'completed'
    end
  end
end
