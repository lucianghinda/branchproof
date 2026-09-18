# frozen_string_literal: true

# PAT-21: Class-constrained structure
Point = Struct.new(:x, :y)

def example(point, x, y)
  value = point ? Point.new(x, y) : [x, y]
  case value
  in Point[a, b] then [a, b]
  else nil
  end
end
