# frozen_string_literal: true

module Branchproof
  # Keep matching and iteration in the original lexical scope.
  module IterationInstrumentation
    private

    # rubocop:disable Metrics/MethodLength
    def render_flow(bytes, decision, nested, encloses)
      metadata = decision.fetch(:instrumentation)
      case metadata[:type]
      when "iteration"
        render_iteration(bytes, decision, nested, encloses)
      when "required_pattern"
        expression = render_children(bytes, decision[:byte_start], decision[:byte_length], nested, encloses)
        runtime = self.class::RUNTIME
        identifier = decision[:id].inspect
        "(begin; #{runtime}.enter(#{identifier}); begin; #{expression}; " \
          "#{runtime}.flow_select(#{identifier}, 0); nil; rescue ::NoMatchingPatternError; " \
          "#{runtime}.flow_select(#{identifier}, 1); raise; ensure; #{runtime}.leave(#{identifier}); end; end)"
      else
        super
      end
    end

    # rubocop:enable Metrics/MethodLength

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def render_iteration(bytes, decision, nested, encloses)
      metadata = decision.fetch(:instrumentation)
      identifier = decision[:id].inspect
      runtime = self.class::RUNTIME
      alternative_count = metadata[:lazy] ? 1 : 2
      marker = "#{runtime}.flow_iteration_callback(#{identifier}, #{alternative_count})"
      suffix = metadata[:empty] ? "nil; " : ""
      edits = [{ start: metadata[:insert_at], length: 0, text: "; #{marker}; #{suffix}" }]
      if metadata[:receiver]
        receiver = metadata.fetch(:receiver)
        edits << flow_replacement(bytes, receiver, nested, encloses) do |expression|
          "#{runtime}.flow_iteration_begin(#{identifier}, (#{expression}), #{alternative_count})"
        end
      end
      expression = flow_fragments(bytes, decision, nested, edits, encloses)
      if metadata[:receiver]
        "(begin; begin; #{runtime}.flow_iteration_finish(#{identifier}, (#{expression}), 0); ensure; " \
          "#{runtime}.flow_iteration_leave(#{identifier}); end; end)"
      else
        flow_frame(decision[:id], expression, default_path: 0)
      end
    end
  end
end
