# frozen_string_literal: true

module Branchproof
  # Each optional parameter has an independent supplied/defaulted obligation.
  module DefaultSyntax
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    private

    def flow_decision_node?(node)
      @default_owner_by_node = {}.compare_by_identity if node.is_a?(Prism::ProgramNode)
      register_default_owner(node) if default_owner_node?(node)
      default_parameter_node?(node) || super
    end

    def flow_details(node, bytes, encoding)
      return super unless default_parameter_node?(node)

      value = node.value
      alternatives = [
        { expression: "#{node.name} supplied", byte_start: node.location.start_offset,
          byte_length: node.location.length },
        { expression: "#{node.name} default evaluated", byte_start: value.location.start_offset,
          byte_length: value.location.length }
      ]
      owner = @default_owner_by_node && @default_owner_by_node[node]
      metadata = { type: "default", value_range: byte_range(value.location) }
      metadata[:owner] = owner if owner
      ["implicit", "default_argument", alternatives, metadata, unsupported_reasons(node, bytes)]
    end

    def register_default_owner(owner)
      @default_owner_by_node ||= {}.compare_by_identity
      parameters = owner.parameters if owner.respond_to?(:parameters)
      parameters = parameters.parameters if parameters.is_a?(Prism::BlockParametersNode)
      return unless parameters.is_a?(Prism::ParametersNode)

      details = default_owner_details(owner)
      (Array(parameters.optionals) + Array(parameters.keywords)).each do |parameter|
        next unless default_parameter_node?(parameter)

        @default_owner_by_node[parameter] = details
      end
    end

    def default_parameter_node?(node)
      node.is_a?(Prism::OptionalParameterNode) || node.is_a?(Prism::OptionalKeywordParameterNode)
    end

    def default_owner_node?(node)
      node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)
    end

    def default_owner_details(owner)
      return nil unless owner

      # Only endless `def name(...) = expr` has a body that can be wrapped as
      # one expression. Lambda/block `closing_loc` values are delimiters, not
      # endless-definition markers, and must stay on the statement path.
      equal_loc = owner.is_a?(Prism::DefNode) && owner.equal_loc
      closing = if owner.is_a?(Prism::DefNode)
                  owner.end_keyword_loc
                else
                  owner.closing_loc
                end
      body_start, body_length = default_owner_body_span(owner, closing)
      details = { byte_start: owner.location.start_offset, byte_length: owner.location.length,
                  equal: equal_loc ? true : false, body_start: body_start,
                  body_length: body_length, closing_start: closing&.start_offset }
      details.freeze
    end

    # Prism represents a method-level `rescue`/`ensure` as an implicit
    # BeginNode whose location covers the whole def. Its insertion point is
    # the actual statements (or rescue/ensure clause), not the def keyword.
    def default_owner_body_span(owner, closing)
      body = owner.body
      if body.is_a?(Prism::BeginNode) && body.begin_keyword_loc.nil?
        statements = body.statements
        start = implicit_begin_start(statements, body, closing)
        finish = closing&.start_offset || (body.location.start_offset + body.location.length)
        return [start, start && finish ? [finish - start, 0].max : nil]
      end

      [body&.location&.start_offset, body&.location&.length]
    end

    def implicit_begin_start(statements, body, closing)
      [statements&.location&.start_offset, body.rescue_clause&.location&.start_offset,
       body.ensure_clause&.location&.start_offset, closing&.start_offset].compact.first
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
end
