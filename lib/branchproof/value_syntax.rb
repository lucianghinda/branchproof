# frozen_string_literal: true

require "prism"

module Branchproof
  # Inventory for expressions whose result is itself the observable value.
  # This deliberately excludes control-flow predicates already owned by Source.
  module ValueSyntax
    BOOLEAN_OPERATORS = %i[== != < <= > >= === =~ !~].freeze
    DISPATCH_METHODS = %i[public_send send __send__].freeze

    # rubocop:disable-next Metrics/ParameterLists -- source seam mirrors Source#decisions_for.
    def additional_decisions_for(program, bytes, source_id, file_reasons, encoding, decisions:, collected:)
      occupied = decisions.each_with_object({}) do |decision, ranges|
        ranges[range_key(decision[:byte_start], decision[:byte_length])] = true
        Array(decision[:conditions]).each do |condition|
          ranges[range_key(condition[:byte_start], condition[:byte_length])] = true
        end
      end
      value_decisions_for(
        program, bytes, source_id, nodes: collected.fetch(:value_nodes), occupied_ranges: occupied,
                                   file_reasons: file_reasons, encoding: encoding
      )
    end

    # `nodes:` is supplied by Source's fused AST walk. It remains optional for
    # the standalone discovery API used by focused syntax tests.
    # rubocop:disable-next Metrics/MethodLength, Metrics/ParameterLists -- source seam mirrors Source#decisions_for.
    def value_decisions_for(program, bytes, source_id, nodes: nil, occupied_ranges: {}, file_reasons: [],
                            encoding: "UTF-8")
      occupied = occupied_ranges.transform_keys do |range|
        range.is_a?(Array) ? range_key(*range) : range
      end
      decisions = []
      each_value_node(program, nodes) do |node|
        spec = value_spec(node)
        next unless spec

        key = range_key(node.location.start_offset, node.location.length)
        next if occupied[key]

        decisions << build_value_decision(node, spec, bytes, source_id, file_reasons, encoding)
        occupied[key] = true
      end
      decisions
    end

    private

    def value_candidate_node?(node)
      !value_spec(node).nil?
    end

    def each_value_node(program, nodes, &)
      return nodes.each(&) if nodes

      walker = respond_to?(:walk_skipping_defined_operands, true) ? :walk_skipping_defined_operands : :walk
      send(walker, program, &)
    end

    def range_key(start_offset, length)
      (start_offset << 32) | length
    end

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
                    instrumentation: { type: "value", domain: spec.fetch(:domain) })
    end
  end
end
