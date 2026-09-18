# frozen_string_literal: true

module Branchproof
  # Binding events are immediate; no pending state survives a failed default.
  module DefaultRuntime
    def default_binding(decision_id, index)
      enter(decision_id)
      begin
        flow_path(decision_id, index)
      ensure
        leave(decision_id)
      end
      nil
    end
  end
end
