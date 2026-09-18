# frozen_string_literal: true

# FLOW-09: Lambda return and break stay local
def example(use_break)
  operation = lambda do
    break 'broken' if use_break
    return 'returned'
  end
  [operation.call, 'continued']
end
