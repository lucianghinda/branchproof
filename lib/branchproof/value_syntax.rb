# frozen_string_literal: true

require "prism"

module Branchproof
  # Inventory for expressions whose result is itself the observable value.
  # This deliberately excludes control-flow predicates already owned by Source.
  module ValueSyntax
    BOOLEAN_OPERATORS = %i[== != < <= > >= === =~ !~].freeze
    BITWISE_OPERATORS = %i[& | ^].freeze
    DISPATCH_METHODS = %i[public_send send __send__].freeze

    def decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8")
      decisions = super
      occupied = decisions.flat_map do |decision|
        ranges = [[decision[:byte_start], decision[:byte_length]]]
        ranges.concat(Array(decision[:conditions]).map { |condition| condition.values_at(:byte_start, :byte_length) })
        ranges
      end
      decisions + value_decisions_for(program, bytes, source_id, occupied_ranges: occupied,
                                                                 file_reasons: file_reasons, encoding: encoding)
    end

    # rubocop:disable-next Metrics/MethodLength, Metrics/ParameterLists -- source seam mirrors Source#decisions_for.
    def value_decisions_for(program, bytes, source_id, occupied_ranges: [], file_reasons: [], encoding: "UTF-8")
      occupied = occupied_ranges.to_h { |range| [range, true] }
      decisions = []
      walker = respond_to?(:walk_skipping_defined_operands, true) ? :walk_skipping_defined_operands : :walk
      send(walker, program) do |node|
        spec = value_spec(node)
        next unless spec

        range = [node.location.start_offset, node.location.length]
        next if occupied[range]

        decisions << build_value_decision(node, spec, bytes, source_id, file_reasons, encoding)
        occupied[range] = true
      end
      decisions
    end

    private

    # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def value_spec(node)
      if Prism.const_defined?(:MatchWriteNode) && node.is_a?(Prism::MatchWriteNode)
        return { context: "match_capture", domain: :truthiness, alternatives: %w[false true], type: "value" }
      end
      return nil unless node.is_a?(Prism::CallNode)

      name = node.name.to_sym
      if name == :<=>
        return { context: "comparison", domain: :comparison, alternatives: %w[negative zero positive nil],
                 type: "value" }
      end
      return { context: "lookup", domain: :lookup, alternatives: %w[truthy false nil], type: "value" } if name == :[]
      if DISPATCH_METHODS.include?(name)
        return { context: "dispatch", domain: :dispatch, alternatives: %w[success exception],
                 type: "value" }
      end
      if BITWISE_OPERATORS.include?(name)
        return { context: "bitwise", domain: :truthiness, alternatives: %w[false true],
                 type: "value" }
      end
      if BOOLEAN_OPERATORS.include?(name) || name.to_s.end_with?("?")
        return { context: "predicate", domain: :truthiness, alternatives: %w[false true],
                 type: "value" }
      end

      nil
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity -- record assembly is intentionally explicit.
    def build_value_decision(node, spec, bytes, source_id, file_reasons, encoding)
      location = node.location
      expression = text_value(bytes.byteslice(location.start_offset, location.length), encoding)
      alternatives = spec.fetch(:alternatives).each_with_index.map do |label, index|
        { index: index, id: nil, expression: label, byte_start: location.start_offset, byte_length: location.length }
      end
      id = Records.decision_id(source_id: source_id, context: spec.fetch(:context),
                               byte_start: location.start_offset, byte_length: location.length,
                               tree: nil)
      alternatives = alternatives.map { |item| item.merge(id: Records.condition_id(id, item.fetch(:index))) }
      kind = alternatives.length == 2 ? "implicit" : "multiway"
      reasons = Array(file_reasons)
      reasons += Array(unsupported_reasons(node, bytes)) if respond_to?(:unsupported_reasons, true)
      limit = @limits[:conditions_per_decision] if defined?(@limits) && @limits.respond_to?(:[])
      reasons << "alternative_limit_exceeded" if limit && alternatives.length > limit
      Records.build(id: id, source_id: source_id, kind: kind, context: spec.fetch(:context),
                    byte_start: location.start_offset, byte_length: location.length,
                    line: location.start_line, column: location.start_column,
                    expression: expression, tree: nil, conditions: [],
                    alternatives: alternatives, discovered_condition_count: 0,
                    support_status: reasons.empty? ? "SUPPORTED" : "UNSUPPORTED",
                    support_reasons: reasons.uniq, opaque_ranges: [],
                    instrumentation: { type: "value", domain: spec.fetch(:domain).to_s })
    end
  end
end
