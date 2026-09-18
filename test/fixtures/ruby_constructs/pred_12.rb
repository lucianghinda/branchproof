# frozen_string_literal: true

# PRED-12: Regexp literal condition implicitly matches $_
def example(text)
  $_ = text
  if /a/
    "match"
  else
    "miss"
  end
end
