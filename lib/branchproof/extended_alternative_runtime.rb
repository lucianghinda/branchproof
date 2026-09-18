# frozen_string_literal: true

module Branchproof
  # Runtime hooks for decisions whose native evaluation has a third path.
  # Runtime includes this module explicitly; it is kept separate so the
  # ordinary two-path helpers remain unchanged.
  module ExtendedAlternativeRuntime
    def flow_assignment_receiver(decision_id, receiver)
      flow_select(decision_id, 0) if nil.equal?(receiver)
      receiver
    end

    def flow_assignment_path(decision_id, index)
      flow_select(decision_id, index)
    end

    def flow_assignment_finish(decision_id, value, default_path = nil)
      frame = current_frame(decision_id)
      flow_select(decision_id, default_path) if frame && !frame[:finished] && !default_path.nil?
      value
    end
  end
end
