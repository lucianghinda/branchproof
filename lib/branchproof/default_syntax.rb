# frozen_string_literal: true

module Branchproof
  # Each optional parameter has an independent supplied/defaulted obligation.
  module DefaultSyntax
    private

    def flow_decision_node?(node)
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
      metadata = { type: "default", value_range: byte_range(value.location) }
      ["implicit", "default_argument", alternatives, metadata, unsupported_reasons(node, bytes)]
    end

    def default_parameter_node?(node)
      node.is_a?(Prism::OptionalParameterNode) || node.is_a?(Prism::OptionalKeywordParameterNode)
    end
  end
end
