# frozen_string_literal: true

# Keep each bounded source rewrite together so its evaluation order can be audited.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength

module Branchproof
  # Source-location edits around Ruby's native matching and assignment operations.
  module FlowInstrumentation
    private

    def render_flow(bytes, decision, nested)
      metadata = decision.fetch(:instrumentation)
      case metadata.fetch(:type)
      when "safe_navigation"
        receiver = metadata.fetch(:receiver)
        replacements = [flow_replacement(bytes, receiver, nested) do |expression|
          "#{self.class::RUNTIME}.flow_receiver(#{decision[:id].inspect}, (#{expression}))"
        end]
        flow_fragments(bytes, decision, nested, replacements)
      when "assignment"
        rhs = metadata.fetch(:rhs)
        replacements = [flow_replacement(bytes, rhs, nested) do |expression|
          "(begin; #{self.class::RUNTIME}.flow_path(#{decision[:id].inspect}, 1); (#{expression}); end)"
        end]
        expression = flow_fragments(bytes, decision, nested, replacements)
        flow_frame(decision[:id], expression, default_path: 0)
      when "case"
        render_case_flow(bytes, decision, nested, metadata)
      when "case_match"
        render_pattern_flow(bytes, decision, nested, metadata)
      else
        raise ArgumentError, "unknown instrumentation type: #{metadata[:type]}"
      end
    end

    def render_case_flow(bytes, decision, nested, metadata)
      identifier = decision[:id].inspect
      runtime = self.class::RUNTIME
      replacements = metadata.fetch(:candidates).map do |candidate|
        flow_replacement(bytes, candidate, nested) do |expression|
          "(begin; #{runtime}.flow_candidate(#{identifier}, #{candidate[:index]}); (#{expression}); end)"
        end
      end
      metadata.fetch(:branches).each do |branch|
        suffix = branch[:empty] ? "nil; " : ""
        replacements << { start: branch[:insert_at], length: 0,
                          text: "; #{runtime}.flow_selected(#{identifier}); #{suffix}" }
      end
      if metadata[:else]
        alternative = metadata[:else]
        replacements << { start: alternative[:insert_at], length: 0,
                          text: "; #{runtime}.flow_select(#{identifier}, #{alternative[:index]}); " }
      else
        index = decision.fetch(:alternatives).length - 1
        replacements << { start: metadata.fetch(:end_start), length: 0,
                          text: "else; #{runtime}.flow_select(#{identifier}, #{index}); nil; " }
      end
      flow_frame(decision[:id], flow_fragments(bytes, decision, nested, replacements))
    end

    def render_pattern_flow(bytes, decision, nested, metadata)
      identifier = decision[:id].inspect
      runtime = self.class::RUNTIME
      replacements = metadata.fetch(:branches).map do |branch|
        suffix = branch[:empty] ? "nil; " : ""
        { start: branch[:insert_at], length: 0,
          text: "; #{runtime}.flow_select(#{identifier}, #{branch[:index]}); #{suffix}" }
      end
      if metadata[:else]
        alternative = metadata[:else]
        replacements << { start: alternative[:insert_at], length: 0,
                          text: "; #{runtime}.flow_select(#{identifier}, #{alternative[:index]}); " }
      end
      flow_frame(decision[:id], flow_fragments(bytes, decision, nested, replacements))
    end

    def flow_replacement(bytes, location, nested)
      start = location.fetch(:byte_start)
      length = location.fetch(:byte_length)
      { start: start, length: length, text: yield(render_children(bytes, start, length, nested)) }
    end

    def flow_fragments(bytes, decision, nested, replacements)
      cursor = decision.fetch(:byte_start)
      finish = cursor + decision.fetch(:byte_length)
      chunks = []
      replacements.sort_by { |edit| [edit[:start], edit[:length]] }.each do |edit|
        raise ArgumentError, "overlapping flow edits" if edit[:start] < cursor

        chunks << render_children(bytes, cursor, edit[:start] - cursor, nested)
        chunks << edit[:text]
        cursor = edit[:start] + edit[:length]
      end
      chunks << render_children(bytes, cursor, finish - cursor, nested)
      chunks.join
    end

    def flow_frame(decision_id, expression, default_path: nil)
      runtime = self.class::RUNTIME
      "(begin; #{runtime}.enter(#{decision_id.inspect}); begin; " \
        "#{runtime}.flow_finish(#{decision_id.inspect}, (#{expression}), #{default_path.inspect}); ensure; " \
        "#{runtime}.leave(#{decision_id.inspect}); end; end)"
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
