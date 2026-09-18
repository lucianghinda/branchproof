# frozen_string_literal: true

# PRED-17: Lookup returns stored false and nil as well as truthy values
def example(key)
  { "ready" => "yes", "disabled" => false, "empty" => nil }[key]
end
