# frozen_string_literal: true

module Branchproof
  # Observe entry into source-visible callback bodies, not library internals.
  module IterationSyntax
    ITERATORS = %i[each each_with_index times upto downto step map collect select filter reject filter_map
                   find detect find_index take_while drop_while partition count all? any? none? one? fetch].freeze

    private

    def flow_decision_node?(node)
      iteration_node?(node) || node.is_a?(Prism::MatchRequiredNode) || super
    end

    def iteration_node?(node)
      node.is_a?(Prism::ForNode) ||
        (node.is_a?(Prism::CallNode) && ITERATORS.include?(node.name) &&
         node.block.is_a?(Prism::BlockNode) && !node.safe_navigation?)
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def flow_details(node, bytes, encoding)
      if node.is_a?(Prism::MatchRequiredNode)
        alternatives = %w[matched mismatch].map { |label| iteration_alternative(node, label) }
        return ["pattern", "required_pattern", alternatives,
                { type: "required_pattern", range: byte_range(node.location) }, unsupported_reasons(node, bytes)]
      end
      return super unless iteration_node?(node)

      body = node.is_a?(Prism::ForNode) ? node.statements : node.block.body
      closing = node.is_a?(Prism::ForNode) ? node.end_keyword_loc : node.block.closing_loc
      lazy = node.is_a?(Prism::CallNode) && lazy_receiver?(node.receiver)
      fallback = node.is_a?(Prism::CallNode) && node.name == :fetch
      context = if lazy
                  "lazy_callback"
                else
                  (fallback ? "fetch_fallback" : "iteration")
                end
      labels = if lazy
                 ["callback entered"]
               else
                 (fallback ? ["value present", "fallback entered"] : %w[empty entered])
               end
      metadata = { type: "iteration", range: byte_range(node.location), lazy: lazy,
                   insert_at: body&.location&.start_offset || closing.start_offset,
                   empty: body.nil? }
      metadata[:receiver] = byte_range(node.receiver.location) if node.is_a?(Prism::CallNode) && node.receiver
      [lazy ? "multiway" : "implicit", context, labels.map { |label| iteration_alternative(node, label) },
       metadata, unsupported_reasons(node, bytes)]
    end

    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def lazy_receiver?(node)
      node.is_a?(Prism::CallNode) && (node.name == :lazy || lazy_receiver?(node.receiver))
    end

    def iteration_alternative(node, label)
      { expression: label, byte_start: node.location.start_offset, byte_length: node.location.length }
    end
  end
end
