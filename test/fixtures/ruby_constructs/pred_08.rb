# frozen_string_literal: true

# PRED-08: Empty and nonempty collections
def example(values)
  [values.empty?, values.size.zero?, values.length > 0]
end
