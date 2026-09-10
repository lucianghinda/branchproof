# frozen_string_literal: true

module Branchproof
  # Records native Ruby path selection without evaluating application values twice.
  module RuntimeFlow
    def flow_candidate(decision_id, index)
      frame = current_frame(decision_id)
      frame[:observations] << [index, false] if frame
      nil
    end

    def flow_selected(decision_id)
      frame = current_frame(decision_id)
      if frame && !frame[:observations].empty?
        frame[:observations].last[1] = true
        frame[:outcome] = true
        frame[:finished] = true
      end
      nil
    end

    def flow_select(decision_id, index)
      frame = current_frame(decision_id)
      if frame
        frame[:observations] = (0..index).map { |position| [position, position == index] }
        frame[:outcome] = true
        frame[:finished] = true
      end
      nil
    end

    def flow_path(decision_id, index)
      frame = current_frame(decision_id)
      if frame
        frame[:observations] = [[0, index.zero?], [1, index == 1]]
        frame[:outcome] = true
        frame[:finished] = true
      end
      nil
    end

    def flow_finish(decision_id, value, default_path = nil)
      frame = current_frame(decision_id)
      flow_path(decision_id, default_path) if frame && !frame[:finished] && !default_path.nil?
      value
    end

    def flow_receiver(decision_id, receiver)
      enter(decision_id)
      begin
        flow_path(decision_id, nil.equal?(receiver) ? 0 : 1)
      ensure
        leave(decision_id)
      end
      receiver
    end
  end
end
