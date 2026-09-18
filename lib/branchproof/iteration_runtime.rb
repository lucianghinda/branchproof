# frozen_string_literal: true

module Branchproof
  # Runtime support for callback based iteration, including lazy receivers
  # whose callbacks execute after the constructing call has returned.
  module IterationRuntime
    def flow_iteration_begin(decision_id, receiver, alternative_count = 2)
      # Case equality bypasses an application's overridden `is_a?` method.
      # rubocop:disable-next Style/CaseEquality
      return receiver if alternative_count == 1 || ::Enumerator::Lazy === receiver

      enter(decision_id)
      receiver
    end

    # rubocop:disable-next Metrics/MethodLength
    def flow_iteration_callback(decision_id, alternative_count = 2)
      frame = iteration_frame(decision_id)
      if frame
        return nil if frame[:finished]

        iteration_select(frame, alternative_count.to_i == 1 ? 0 : 1, alternative_count)
      else
        enter(decision_id)
        begin
          if alternative_count.to_i == 1
            flow_select(decision_id, 0)
          else
            flow_path(decision_id, 1)
          end
        ensure
          leave(decision_id)
        end
      end
      nil
    end

    def flow_iteration_finish(decision_id, value, default_path = nil)
      frame = iteration_frame(decision_id)
      iteration_select(frame, default_path, 2) if frame && !frame[:finished] && !default_path.nil?
      value
    end

    def flow_iteration_leave(decision_id)
      frame = iteration_frame(decision_id)
      frames = Thread.current[Branchproof::Runtime::FRAME_STATE_KEY]&.fetch(:frames, nil)
      return nil unless frame && frames&.last.equal?(frame)

      leave(decision_id)
    end

    private

    # `current_frame` deliberately latches a diagnostic when a helper probes
    # while another decision is active. Iteration callbacks may be deferred or
    # nested, so an absent matching frame is an ordinary state here.
    def iteration_frame(decision_id)
      frames = Thread.current[Branchproof::Runtime::FRAME_STATE_KEY]&.fetch(:frames, nil)
      index = frames ? frames.length - 1 : -1
      while index >= 0
        frame = frames[index]
        return frame if frame[:decision_id] == decision_id

        index -= 1
      end
      nil
    end

    def iteration_select(frame, index, alternative_count)
      frame[:observations] = if alternative_count == 1
                               [[0, true]]
                             else
                               [[0, index.zero?], [1, index == 1]]
                             end
      frame[:outcome] = true
      frame[:finished] = true
    end
  end
end
