# frozen_string_literal: true

# API-10: Dynamic method dispatch
def example(value, method_name)
  value.public_send(method_name)
end
