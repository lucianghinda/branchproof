# frozen_string_literal: true

# EXC-02: Bare rescue catches StandardError only
def example(outside)
  begin
    begin
      raise(outside ? ScriptError : RuntimeError)
    rescue
      'handled'
    end
  rescue ScriptError
    'outside StandardError'
  end
end
