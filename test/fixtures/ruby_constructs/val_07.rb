# frozen_string_literal: true

# VAL-07: Interpolation and container contents can contain decisions
def example(ready)
  text = "chosen:#{ready ? 'yes' : 'no'}"
  values = [ready ? "yes" : nil]
  [text ? "yes" : "no", values ? "yes" : "no", text]
end
