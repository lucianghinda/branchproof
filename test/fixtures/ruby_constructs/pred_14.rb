# frozen_string_literal: true

# PRED-14: defined? does not invoke the missing method
def example(value)
  [defined?(value), defined?(String), defined?(missing_catalog_method())]
end
