# frozen_string_literal: true

# PRED-06: Type and capability predicates
def example(value)
  [value.is_a?(String), value.kind_of?(String), value.instance_of?(String), value.respond_to?(:length)]
end
