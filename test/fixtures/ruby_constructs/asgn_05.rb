# frozen_string_literal: true

# ASGN-05: Constant assignment in legal module bodies
module ExistingSetting
  VALUE = "old"
  VALUE ||= "new"
end

module MissingSetting
  VALUE ||= "new"
end

def example
  [ExistingSetting::VALUE, MissingSetting::VALUE]
end
