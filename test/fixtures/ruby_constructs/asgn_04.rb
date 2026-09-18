# frozen_string_literal: true

# ASGN-04: Instance, class, and global assignment targets
class Settings
  def self.example(initialize_values, initial)
    if initialize_values
      @value = initial
      @@value = initial
      $example_value = initial
    end
    @value ||= "new"
    @@value ||= "new"
    $example_value ||= "new"
    [@value, @@value, $example_value]
  end
end

def example(initialize_values, initial)
  Settings.example(initialize_values, initial)
end
