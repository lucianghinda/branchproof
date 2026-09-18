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
      if iteration_frame(decision_id)
        flow_path(decision_id, 1)
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
      flow_path(decision_id, default_path) if frame && !frame[:finished] && !default_path.nil?
      value
    end

    def flow_iteration_leave(decision_id)
      return nil unless iteration_frame(decision_id)

      leave(decision_id)
    end

    private

    # `current_frame` deliberately latches a diagnostic when a helper probes
    # while another decision is active. Iteration callbacks may be deferred or
    # nested, so an absent matching frame is an ordinary state here.
    def iteration_frame(decision_id)
      frames = Thread.current[Branchproof::Runtime::FRAME_STATE_KEY]&.fetch(:frames, nil)
      frame = frames&.last
      frame if frame && frame[:decision_id] == decision_id
    end
  end
end
