# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/ConditionalAssignment

require_relative "flow_instrumentation"

module Branchproof
  # Textual edits for native rescue control flow.  The edits only add calls at
  # Ruby's own protected-region and handler boundaries; exception matching,
  # `$!`, retry, ensure ordering, and nonlocal transfers remain Ruby-owned.
  module ExceptionInstrumentation
    private

    def render_flow(bytes, decision, nested, encloses)
      metadata = decision.fetch(:instrumentation)
      return super unless %w[exception rescue_modifier].include?(metadata[:type])

      if metadata[:type] == "exception"
        render_exception_flow(bytes, decision, nested, encloses)
      else
        render_rescue_modifier_flow(bytes, decision, nested, encloses)
      end
    end

    def render_exception_flow(bytes, decision, nested, encloses)
      identifier = decision[:id].inspect
      runtime = self.class::RUNTIME
      metadata = decision.fetch(:instrumentation)
      replacements = []
      if metadata[:normal_insert_at] && !metadata[:normal_empty]
        replacements << { start: metadata.fetch(:normal_insert_at), length: 0,
                          text: "; #{runtime}.exception_path(#{identifier}, 0); " }
      elsif metadata[:normal_transfer]
        transfer = metadata.fetch(:normal_transfer)
        if transfer[:arguments]
          replacements << flow_replacement(bytes, transfer.fetch(:arguments), nested, encloses) do |arguments|
            value = transfer[:argument_mode] == :array ? "[#{arguments}]" : "(#{arguments})"
            "#{runtime}.exception_value(#{identifier}, #{value}, 0)"
          end
        else
          replacements << { start: transfer.fetch(:insert_at), length: 0,
                            text: "#{runtime}.exception_path(#{identifier}, 0); " }
        end
      elsif metadata[:normal_body] && metadata[:normal_body][:byte_length].positive?
        replacements << flow_replacement(bytes, metadata.fetch(:normal_body), nested, encloses) do |body|
          "#{runtime}.exception_value(#{identifier}, (begin; #{body}; end), 0)"
        end
      end
      metadata.fetch(:clauses).each do |clause|
        replacements << { start: clause.fetch(:insert_at), length: 0,
                          text: "; #{runtime}.exception_path(#{identifier}, #{clause.fetch(:index)}); " }
      end
      if metadata[:implicit]
        entry = "begin; #{runtime}.exception_enter(#{identifier}, #{metadata.fetch(:unhandled_index)}); begin; "
        entry += "#{runtime}.exception_path(#{identifier}, 0); " if metadata[:normal_empty]
        exit = "; end; rescue ::Exception; #{runtime}.exception_unhandled(#{identifier}); raise; ensure; " \
               "#{runtime}.exception_leave(#{identifier}); end; "
        replacements << { start: metadata.fetch(:entry_insert_at), length: 0, text: entry }
        replacements << { start: metadata.fetch(:exit_insert_at), length: 0, text: exit }
        flow_fragments(bytes, decision, nested, replacements, encloses)
      else
        expression = flow_fragments(bytes, decision, nested, replacements, encloses)
        exception_frame(decision[:id], expression, metadata.fetch(:unhandled_index))
      end
    end

    def render_rescue_modifier_flow(bytes, decision, nested, encloses)
      identifier = decision[:id].inspect
      runtime = self.class::RUNTIME
      metadata = decision.fetch(:instrumentation)
      lhs = metadata.fetch(:expression)
      rhs = metadata.fetch(:rescue_expression)
      replacements = [
        flow_replacement(bytes, lhs, nested, encloses) do |expression|
          "#{runtime}.exception_value(#{identifier}, (#{expression}), 0)"
        end,
        flow_replacement(bytes, rhs, nested, encloses) do |expression|
          "(begin; #{runtime}.exception_path(#{identifier}, 1); (#{expression}); end)"
        end
      ]
      exception_frame(decision[:id], flow_fragments(bytes, decision, nested, replacements, encloses),
                      metadata.fetch(:unhandled_index))
    end

    def exception_frame(decision_id, expression, unhandled_index)
      runtime = self.class::RUNTIME
      "(begin; #{runtime}.exception_enter(#{decision_id.inspect}, #{unhandled_index}); begin; " \
        "#{expression}; " \
        "rescue ::Exception; #{runtime}.exception_unhandled(#{decision_id.inspect}); raise; ensure; " \
        "#{runtime}.exception_leave(#{decision_id.inspect}); end; end)"
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/ConditionalAssignment
