# frozen_string_literal: true

module Branchproof
  # Record native clause selection and escaping exceptions. Generated wrappers
  # re-raise the same exception; nonlocal transfers remain aborted observations.
  module ExceptionRuntime
    def exception_enter(decision_id, unhandled_index)
      enter(decision_id)
      frame = current_frame(decision_id)
      frame[:exception_unhandled_index] = unhandled_index if frame
      nil
    end

    def exception_path(decision_id, index)
      frame = current_frame(decision_id)
      flow_select(decision_id, index) if frame && !frame[:finished]
      nil
    end

    def exception_value(decision_id, value, index)
      exception_path(decision_id, index)
      value
    end

    def exception_finish(decision_id, value)
      frame = current_frame(decision_id)
      exception_path(decision_id, 0) if frame && !frame[:finished]
      value
    end

    def exception_unhandled(decision_id)
      frame = current_frame(decision_id)
      exception_path(decision_id, frame[:exception_unhandled_index]) if frame && !frame[:finished]
      nil
    end

    def exception_leave(decision_id)
      leave(decision_id)
    end
  end
end
