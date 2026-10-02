# frozen_string_literal: true

# FALL-01: Value fallback chain ending in a literal
def example(name, title)
  name || title || "untitled"
end
