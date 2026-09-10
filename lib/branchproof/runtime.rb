# frozen_string_literal: true

require "securerandom"
require_relative "runtime_flow"

module Branchproof
  # Process-local execution recorder. It deliberately never coerces or stores
  # application values: Ruby's conditional expression is used for truthiness.
  # Captures condition evaluations while preserving application values.
  module Runtime
    extend RuntimeFlow

    FRAME_STATE_KEY = :branchproof_runtime_frame_state

    class << self
      def boot(evidence:)
        return nil if defined?(@booted) && @booted && @evidence.equal?(evidence) && Process.pid == @process_id

        @evidence = evidence
        @run_id = evidence.respond_to?(:run_id) ? evidence.run_id.to_s : SecureRandom.hex(16)
        @process_id = Process.pid
        @diagnostics = []
        @storage_disabled = false
        @booted = true
        nil
      end

      def enter(decision_id)
        state[:frames] << { decision_id: String(decision_id), context: state[:context]&.dup,
                            observations: [], outcome: nil, finished: false }
        nil
      end

      def condition(decision_id, index, value)
        frame = current_frame(decision_id)
        if frame
          truth = value ? true : false
          frame[:observations] << [Integer(index), truth]
        end
        value
      end

      def finish(decision_id, value)
        frame = current_frame(decision_id)
        if frame
          frame[:outcome] = (value ? true : false)
          frame[:finished] = true
        end
        value
      end

      def leave(decision_id)
        detect_fork
        frames = state[:frames]
        frame = frames.pop
        unless frame && frame[:decision_id] == String(decision_id)
          latch("runtime_frame_mismatch", "decision frame stack is not balanced")
          cleanup_state
          return nil
        end
        return nil unless @evidence && !@storage_disabled

        execution = {
          run_id: @run_id,
          decision_id: frame[:decision_id],
          test_id: frame[:context]&.fetch(:test_id, nil),
          phase: frame[:context]&.fetch(:phase, "unattributed") || "unattributed",
          observations: frame[:observations].map(&:dup),
          outcome: frame[:finished] ? frame[:outcome] : nil,
          status: frame[:finished] ? "completed" : "aborted"
        }
        safely_record(execution)
        cleanup_state
        nil
      end

      def context(test_id:, phase:)
        state[:context] = if test_id.nil? || phase.to_s == "unattributed"
                            nil
                          else
                            { test_id: test_id, phase: phase }
                          end
        nil
      end

      def register_test(test:)
        return nil unless @evidence.respond_to?(:register_test)

        result = @evidence.register_test(test: test)
        unless result.is_a?(Hash) && result[:status].to_s == "registered"
          reported = result.is_a?(Hash) ? result[:status] : result.class
          latch("recorder_status", "test registration returned #{reported}")
        end
        result
      rescue StandardError => e
        latch("recorder_failure", "test registration failed: #{e.class}: #{e.message}")
        nil
      end

      def snapshot
        if @evidence.respond_to?(:snapshot)
          result = @evidence.snapshot
          return result if @diagnostics.nil? || @diagnostics.empty?

          copy = Marshal.load(Marshal.dump(result))
          copy[:diagnostics] = Array(copy[:diagnostics]) + @diagnostics
          copy[:completeness] = (copy[:completeness] || {}).merge(observation: false)
          return copy
        end
        { observations: [], diagnostics: @diagnostics.dup,
          completeness: { observation: true, attribution: true, analysis: true } }
      end

      def diagnostics
        @diagnostics&.map(&:dup) || []
      end

      private

      def state
        Thread.current[FRAME_STATE_KEY] ||= { frames: [], context: nil }
      end

      def cleanup_state
        current = Thread.current[FRAME_STATE_KEY]
        Thread.current[FRAME_STATE_KEY] = nil if current && current[:frames].empty? && current[:context].nil?
      end

      def detect_fork
        return unless @process_id && Process.pid != @process_id

        @process_id = Process.pid
        @diagnostics = [{ code: "forked_process", severity: "error",
                          message: "runtime process identity changed; evidence storage disabled",
                          source_id: nil, decision_id: nil, execution_id: nil, test_id: nil, details: {} }]
        @storage_disabled = true
      end

      def current_frame(decision_id)
        frame = state[:frames].last
        return frame if frame && frame[:decision_id] == String(decision_id)

        latch("runtime_frame_mismatch", "no active frame for #{decision_id}") if frame
        nil
      end

      def safely_record(execution)
        result = @evidence.record(execution: execution)
        unless result.is_a?(Hash) && result[:status].to_s == "recorded"
          reported = result.is_a?(Hash) ? result[:status] : result.class
          latch("recorder_status", "evidence recorder returned #{reported}")
        end
        result
      rescue StandardError => e
        latch("recorder_failure", "evidence recorder failed: #{e.class}: #{e.message}")
      end

      def latch(code, message)
        @storage_disabled = true
        @diagnostics ||= []
        @diagnostics << { code: code, severity: "error", message: message,
                          source_id: nil, decision_id: nil, execution_id: nil, test_id: nil, details: {} }
      end
    end
  end
end
