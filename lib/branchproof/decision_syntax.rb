# frozen_string_literal: true

module Branchproof
  # Discovers control-flow expressions whose truth is not represented by an
  # ordinary Prism IfNode.  The records intentionally contain byte ranges and
  # scalar metadata only; Prism nodes must not escape the source pass.
  module DecisionSyntax
    OR_WRITE_NODE_NAMES = %w[
      CallOrWriteNode ClassVariableOrWriteNode ConstantOrWriteNode
      ConstantPathOrWriteNode GlobalVariableOrWriteNode IndexOrWriteNode
      InstanceVariableOrWriteNode LocalVariableOrWriteNode
    ].freeze

    AND_WRITE_NODE_NAMES = %w[
      CallAndWriteNode ClassVariableAndWriteNode ConstantAndWriteNode
      ConstantPathAndWriteNode GlobalVariableAndWriteNode IndexAndWriteNode
      InstanceVariableAndWriteNode LocalVariableAndWriteNode
    ].freeze

    def flow_decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8")
      nodes = []
      walk(program) { |node| nodes << node if flow_decision_node?(node) }
      nodes.sort_by { |node| [node.location.start_offset, node.location.length] }.map do |node|
        build_flow_decision(node, bytes, source_id, file_reasons, encoding)
      end
    end

    private

    def flow_decision_node?(node)
      return true if node.is_a?(Prism::CaseNode) && node.predicate
      return true if node.is_a?(Prism::CaseMatchNode)
      return true if node.is_a?(Prism::CallNode) && node.safe_navigation?
      return true if assignment_node?(node)
      return true if node.is_a?(Prism::RescueNode) || node.is_a?(Prism::RescueModifierNode)

      false
    end

    def assignment_node?(node)
      OR_WRITE_NODE_NAMES.include?(node.class.name.split("::").last) ||
        AND_WRITE_NODE_NAMES.include?(node.class.name.split("::").last)
    end

    def build_flow_decision(node, bytes, source_id, file_reasons, encoding)
      location = node.location
      kind, context, alternatives, instrumentation, reasons = flow_details(node, bytes, encoding)
      reasons = Array(file_reasons) + Array(reasons)
      decision_id = Records.decision_id(source_id: source_id, context: context,
                                        byte_start: location.start_offset, byte_length: location.length, tree: nil)
      alternatives = alternatives.each_with_index.map do |alternative, index|
        alternative.merge(index: index, id: Records.condition_id(decision_id, index))
      end
      limit = @limits[:conditions_per_decision] if defined?(@limits) && @limits.respond_to?(:[])
      reasons << "alternative_limit_exceeded" if limit && alternatives.length > limit

      Records.build(
        id: decision_id,
        source_id: source_id,
        context: context,
        kind: kind,
        byte_start: location.start_offset,
        byte_length: location.length,
        line: location.start_line,
        column: location.start_column,
        expression: text_value(bytes.byteslice(location.start_offset, location.length), encoding),
        tree: nil,
        conditions: [],
        alternatives: alternatives,
        discovered_condition_count: 0,
        support_status: reasons.empty? ? "SUPPORTED" : "UNSUPPORTED",
        support_reasons: reasons.uniq,
        opaque_ranges: [],
        instrumentation: instrumentation
      )
    end

    def flow_details(node, bytes, encoding)
      case node
      when Prism::CaseNode
        case_details(node, bytes, encoding, kind: "multiway", context: "case")
      when Prism::CaseMatchNode
        case_match_details(node, bytes, encoding)
      when Prism::CallNode
        safe_navigation_details(node, bytes, encoding)
      when Prism::RescueNode, Prism::RescueModifierNode
        rescue_details(node, bytes, encoding)
      else
        assignment_details(node, bytes, encoding)
      end
    end

    def case_details(node, bytes, encoding, kind:, context:)
      conditions = node.conditions
      candidates = []
      branches = []
      conditions.each_with_index do |branch, branch_index|
        branch.conditions.each do |candidate|
          candidates << {
            expression: text_value(bytes.byteslice(candidate.location.start_offset, candidate.location.length),
                                   encoding),
            range: byte_range(candidate.location, splat_node?(candidate) ? "splat" : nil),
            byte_start: candidate.location.start_offset,
            byte_length: candidate.location.length
          }
        end
        branches << {
          index: branch_index,
          insert_at: branch_insert_at(branch, conditions[branch_index + 1], node.else_clause, node.end_keyword_loc),
          empty: statements_empty?(branch.statements)
        }
      end

      else_clause = node.else_clause
      else_index = candidates.length
      candidates << if else_clause
                      { expression: "else", range: byte_range(else_clause.else_keyword_loc),
                        byte_start: else_clause.else_keyword_loc.start_offset,
                        byte_length: else_clause.else_keyword_loc.length }
                    else
                      { expression: "no_match", range: nil, byte_start: node.end_keyword_loc&.start_offset,
                        byte_length: 0 }
                    end
      else_metadata = if else_clause
                        { insert_at: branch_insert_at(else_clause, nil, nil, node.end_keyword_loc), index: else_index,
                          empty: statements_empty?(else_clause.statements) }
                      end
      reasons = unsupported_reasons(node, bytes)
      reasons << "unsupported_case_splat" if candidates.any? do |candidate|
        candidate[:range] && candidate[:range][:kind] == "splat"
      end
      instrumentation = {
        type: "case",
        range: byte_range(node.location),
        predicate: node.predicate && byte_range(node.predicate.location),
        candidates: candidates.reject { |candidate| candidate[:expression] == "else" || candidate[:range].nil? }
                              .each_with_index.map { |candidate, index| candidate.merge(index: index) },
        branches: branches,
        else: else_metadata,
        end_start: node.end_keyword_loc&.start_offset
      }
      alternatives = candidates.map do |candidate|
        candidate.slice(:expression, :byte_start, :byte_length)
      end
      [kind, context, alternatives, instrumentation, reasons]
    end

    def case_match_details(node, bytes, encoding)
      conditions = node.conditions
      candidates = []
      branches = []
      reasons = []
      conditions.each_with_index do |branch, branch_index|
        pattern = branch.pattern
        guarded = pattern.is_a?(Prism::IfNode) || pattern.is_a?(Prism::UnlessNode)
        guard = guarded ? pattern.predicate : nil
        pattern_node = guarded ? pattern.statements&.body&.first : pattern
        reasons << "unsupported_pattern_guard" if guard
        candidate_node = pattern_node || pattern
        candidates << {
          expression: text_value(bytes.byteslice(candidate_node.location.start_offset, candidate_node.location.length),
                                 encoding),
          range: byte_range(candidate_node.location),
          byte_start: candidate_node.location.start_offset,
          byte_length: candidate_node.location.length,
          guard: guard && byte_range(guard.location)
        }
        branches << {
          index: branch_index,
          insert_at: branch_insert_at(branch, conditions[branch_index + 1], node.else_clause, node.end_keyword_loc),
          empty: statements_empty?(branch.statements)
        }
      end
      else_clause = node.else_clause
      else_metadata = if else_clause
                        { insert_at: branch_insert_at(else_clause, nil, nil, node.end_keyword_loc), index: nil,
                          empty: statements_empty?(else_clause.statements) }
                      end
      instrumentation = {
        type: "case_match",
        range: byte_range(node.location),
        predicate: node.predicate && byte_range(node.predicate.location),
        candidates: candidates.reject { |candidate| candidate[:expression] == "else" || candidate[:range].nil? }
                              .each_with_index.map { |candidate, index| candidate.merge(index: index) },
        branches: branches,
        else: else_metadata,
        end_start: node.end_keyword_loc&.start_offset
      }
      if node.else_clause
        else_location = node.else_clause.else_keyword_loc
        candidates << { expression: "else", range: byte_range(else_location),
                        byte_start: else_location.start_offset, byte_length: else_location.length }
        else_index = candidates.length - 1
        instrumentation[:else] = instrumentation[:else].merge(index: else_index)
      end
      alternatives = candidates.map { |candidate| candidate.slice(:expression, :byte_start, :byte_length) }
      ["pattern", "case_in", alternatives, instrumentation, unsupported_reasons(node, bytes) + reasons]
    end

    def safe_navigation_details(node, bytes, _encoding)
      receiver = node.receiver
      instrumentation = {
        type: "safe_navigation",
        range: byte_range(node.location),
        receiver: byte_range(receiver.location)
      }
      alternatives = [
        { expression: "receiver nil", byte_start: receiver.location.start_offset,
          byte_length: receiver.location.length },
        { expression: "receiver non-nil", byte_start: receiver.location.start_offset,
          byte_length: receiver.location.length }
      ]
      ["implicit", "safe_navigation", alternatives, instrumentation, unsupported_reasons(node, bytes)]
    end

    def assignment_details(node, bytes, _encoding)
      rhs = node.value
      operator = bytes.byteslice(node.operator_loc.start_offset, node.operator_loc.length)
      assignment_context = operator == "||=" ? "or_assignment" : "and_assignment"
      reasons = safe_navigation_assignment?(node) ? ["unsupported_assignment_target"] : []
      instrumentation = {
        type: "assignment",
        range: byte_range(node.location),
        rhs: byte_range(rhs.location),
        operator: operator,
        rhs_path: 1,
        skipped_path: 0
      }
      alternatives = if operator == "||="
                       [{ expression: "LHS truthy; RHS skipped", byte_start: node.location.start_offset,
                          byte_length: node.location.length },
                        { expression: "LHS falsey; RHS executed", byte_start: node.location.start_offset,
                          byte_length: node.location.length }]
                     else
                       [{ expression: "LHS falsey; RHS skipped", byte_start: node.location.start_offset,
                          byte_length: node.location.length },
                        { expression: "LHS truthy; RHS executed", byte_start: node.location.start_offset,
                          byte_length: node.location.length }]
                     end
      ["implicit", assignment_context, alternatives, instrumentation, unsupported_reasons(node, bytes) + reasons]
    end

    def rescue_details(node, bytes, encoding)
      alternatives = if node.respond_to?(:exceptions)
                       Array(node.exceptions).map do |exception|
                         {
                           expression: text_value(
                             bytes.byteslice(exception.location.start_offset, exception.location.length), encoding
                           ),
                           byte_start: exception.location.start_offset,
                           byte_length: exception.location.length
                         }
                       end
                     else
                       []
                     end
      instrumentation = { type: "rescue", range: byte_range(node.location) }
      ["exception", "rescue", alternatives, instrumentation, ["unsupported_rescue_control_flow"]]
    end

    def branch_insert_at(branch, next_branch, else_clause, end_keyword_loc)
      statements = branch.statements
      return statements.location.start_offset unless statements_empty?(statements)

      next_location = if next_branch
                        next_branch.is_a?(Prism::InNode) ? next_branch.in_loc : next_branch.keyword_loc
                      end
      next_location&.start_offset || else_clause&.else_keyword_loc&.start_offset ||
        end_keyword_loc&.start_offset || branch.location.end_offset
    end

    def statements_empty?(statements)
      statements.nil? || Array(statements.body).empty?
    end

    def safe_navigation_assignment?(node)
      return true if node.respond_to?(:safe_navigation?) && node.safe_navigation?

      node.respond_to?(:call_operator_loc) && node.call_operator_loc&.slice == "&."
    end

    def splat_node?(node)
      node.class.name.end_with?("SplatNode")
    end

    def byte_range(location, kind = nil)
      return nil unless location

      result = { byte_start: location.start_offset, byte_length: location.length }
      result[:kind] = kind if kind
      result
    end
  end
end
