# frozen_string_literal: true

require "prism"

# Keep source-boundary and parameter-binding rules together for auditing.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

module Branchproof
  # Defaults stay inline in their original lexical scope. A second parse locates
  # body entries after expression edits, avoiding guesses about shifted bytes.
  module DefaultInstrumentation
    def rewrite(unit:)
      rewritten = super
      defaults = Array(unit[:decisions]).select do |decision|
        decision.dig(:instrumentation, :type) == "default" && supported?(decision)
      end
      return rewritten if defaults.empty? || rewritten[:diagnostics].any?

      begin
        bytes = rewritten[:bytes].dup
        flags = defaults.to_h { |decision| [default_flag(decision, unit[:original_bytes]), decision[:id]] }
        edits = default_body_edits(Prism.parse(bytes).value, flags)
        bytes = apply_edits(bytes, edits)
        iseq = RubyVM::InstructionSequence.compile(bytes, unit[:absolute_path] || "(branchproof)",
                                                   unit[:real_path] || "(branchproof)", 1)
        rewritten.merge(bytes: bytes, changed: true, iseq: iseq)
      rescue StandardError, SyntaxError => e
        rewritten.merge(
          bytes: rewritten[:bytes], changed: false, iseq: nil,
          diagnostics: Array(rewritten[:diagnostics]) +
            [diagnostic("invalid_default_rewrite", "#{e.class}: #{e.message}")]
        )
      end
    end

    private

    def render_flow(bytes, decision, nested, encloses)
      return super unless decision.dig(:instrumentation, :type) == "default"

      value = decision.dig(:instrumentation, :value_range)
      flag = default_flag(decision, bytes)
      replacement = flow_replacement(bytes, value, nested, encloses) do |expression|
        "(begin; #{flag} = true; #{self.class::RUNTIME}.default_binding(#{decision[:id].inspect}, 1); " \
          "#{expression}; end)"
      end
      flow_fragments(bytes, decision, nested, [replacement], encloses)
    end

    def default_flag(decision, bytes)
      name = "__branchproof_default_#{decision[:id]}"
      name += "_" while bytes.include?(name)
      name
    end

    def default_body_edits(node, flags)
      return [] unless node

      edits = []
      if node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)
        parameters = node.parameters
        parameters = parameters.parameters if parameters.is_a?(Prism::BlockParametersNode)
        bindings = default_bindings(parameters, flags)
        edits.concat(default_entry_edits(node, bindings)) unless bindings.empty?
      end
      edits + node.compact_child_nodes.flat_map { |child| default_body_edits(child, flags) }
    end

    def default_bindings(parameters, flags)
      return [] unless parameters.is_a?(Prism::ParametersNode)

      (parameters.optionals + parameters.keywords).filter_map do |parameter|
        next unless parameter.respond_to?(:value)

        value = parameter.value
        value = value.body&.body&.first if value.is_a?(Prism::ParenthesesNode)
        if value.is_a?(Prism::BeginNode)
          statements = value&.statements
          first = statements&.body&.first
        end
        name = first.name.to_s if first.is_a?(Prism::LocalVariableWriteNode)
        [name, flags[name]] if flags.key?(name)
      end
    end

    def default_entry_edits(owner, bindings)
      marker = bindings.map do |flag, id|
        "#{self.class::RUNTIME}.default_binding(#{id.inspect}, 0) unless #{flag}; "
      end.join
      body = owner.body
      if owner.is_a?(Prism::DefNode) && owner.equal_loc
        return [] unless body

        start = body.location.start_offset
        finish = body.location.end_offset
        [{ start: start, finish: start, text: "(begin; #{marker}" },
         { start: finish, finish: finish, text: "; end)" }]
      else
        closing = owner.is_a?(Prism::DefNode) ? owner.end_keyword_loc : owner.closing_loc
        return [] unless closing

        start = if body.is_a?(Prism::BeginNode) && body.begin_keyword_loc.nil?
                  body.statements&.location&.start_offset || body.rescue_clause&.keyword_loc&.start_offset ||
                    body.ensure_clause&.ensure_keyword_loc&.start_offset || closing.start_offset
                else
                  body ? body.location.start_offset : closing.start_offset
                end
        [{ start: start, finish: start, text: "#{marker}#{"nil; " unless body}" }]
      end
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
