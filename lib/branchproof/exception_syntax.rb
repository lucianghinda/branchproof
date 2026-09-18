# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

require "prism"

module Branchproof
  # Replaces unsupported standalone rescue-clause records with decisions for
  # Ruby's enclosing protected region.  Ruby chooses a rescue clause as part
  # of executing BeginNode; a RescueNode by itself is not executable syntax.
  module ExceptionSyntax
    private

    def flow_decision_node?(node)
      return true if exception_region_node?(node)
      return false if node.is_a?(Prism::RescueNode)

      super
    end

    def flow_details(node, bytes, encoding)
      return exception_region_details(node, bytes, encoding) if exception_region_node?(node)

      super
    end

    def exception_region_node?(node)
      (node.is_a?(Prism::BeginNode) && (node.rescue_clause || node.ensure_clause)) ||
        node.is_a?(Prism::RescueModifierNode)
    end

    def exception_region_details(node, bytes, encoding)
      return rescue_modifier_details(node, bytes, encoding) if node.is_a?(Prism::RescueModifierNode)

      clauses = []
      clause = node.rescue_clause
      while clause
        clauses << clause
        clause = clause.child_nodes.find { |child| child.is_a?(Prism::RescueNode) }
      end

      alternatives = [{ expression: "normal", byte_start: node.location.start_offset,
                        byte_length: node.location.length }]
      clauses.each do |clause_node|
        alternatives << { expression: rescue_label(clause_node, bytes, encoding),
                          byte_start: clause_node.location.start_offset,
                          byte_length: clause_node.location.length }
      end
      alternatives << { expression: "unhandled", byte_start: node.location.start_offset,
                        byte_length: node.location.length }

      instrumentation = {
        type: "exception",
        range: byte_range(node.location),
        normal_insert_at: node.else_clause && exception_else_insert_at(node),
        normal_body: node.statements && byte_range(node.statements.location),
        implicit: node.begin_keyword_loc.nil?,
        entry_insert_at: node.begin_keyword_loc.nil? && node.statements&.location&.start_offset,
        exit_insert_at: node.begin_keyword_loc.nil? && node.end_keyword_loc&.start_offset,
        clauses: clauses.each_with_index.map do |clause_node, index|
          { index: index + 1, insert_at: exception_clause_insert_at(clause_node, node) }
        end,
        unhandled_index: alternatives.length - 1
      }
      reasons = unsupported_reasons(node, bytes)
      ["exception", "rescue", alternatives, instrumentation, reasons]
    end

    def rescue_modifier_details(node, bytes, _encoding)
      lhs = node.expression
      rhs = node.rescue_expression
      alternatives = [
        { expression: "normal", byte_start: lhs.location.start_offset, byte_length: lhs.location.length },
        { expression: "rescue", byte_start: rhs.location.start_offset, byte_length: rhs.location.length },
        { expression: "unhandled", byte_start: node.location.start_offset, byte_length: node.location.length }
      ]
      instrumentation = {
        type: "rescue_modifier",
        range: byte_range(node.location),
        expression: byte_range(lhs.location),
        rescue_expression: byte_range(rhs.location),
        normal_index: 0,
        rescue_index: 1,
        unhandled_index: 2
      }
      ["exception", "rescue", alternatives, instrumentation, unsupported_reasons(node, bytes)]
    end

    def rescue_label(clause, bytes, encoding)
      exceptions = Array(clause.exceptions)
      return "rescue" if exceptions.empty?

      names = exceptions.map do |exception|
        text_value(bytes.byteslice(exception.location.start_offset, exception.location.length), encoding)
      end
      "rescue #{names.join(", ")}"
    end

    def exception_clause_insert_at(clause, node)
      return clause.statements.location.start_offset unless statements_empty?(clause.statements)

      next_clause = clause.child_nodes.find { |child| child.is_a?(Prism::RescueNode) }
      return next_clause.keyword_loc.start_offset if next_clause
      return node.else_clause.else_keyword_loc.start_offset if node.else_clause
      return node.ensure_clause.ensure_keyword_loc.start_offset if node.ensure_clause

      node.end_keyword_loc.start_offset
    end

    def exception_else_insert_at(node)
      clause = node.else_clause
      return clause.statements.location.start_offset unless statements_empty?(clause.statements)

      node.ensure_clause&.ensure_keyword_loc&.start_offset || node.end_keyword_loc.start_offset
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
