# frozen_string_literal: true

# API-07: Fetch fallback depends on absence, not truthiness
def example(key)
  { "disabled" => false, "empty" => nil }.fetch(key) { "fallback" }
end
