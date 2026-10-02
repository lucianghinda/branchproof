# frozen_string_literal: true

require "prism"

module Branchproof
  # Maps changed lines to current decision records using Prism byte locations.
  # rubocop:disable-next Metrics/ClassLength -- AST ownership rules share the parsed current source and hunk ranges.
  class ChangedDecisionMap
    CONTROL_NODES = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Keeps one Prism walk across all supported contexts.
    def call(bytes:, path:, decisions:, hunks:, old_bytes: "")
      parsed = Prism.parse(bytes)
      unless parsed.errors.empty?
        raise ArgumentError,
              "cannot map changes in #{path.inspect}: current Ruby source does not parse"
      end

      return [] if decisions.empty?

      changed = changed_locations(hunks, old_bytes, bytes)
      return [] if changed.empty?

      selected = []
      old_body_owners = deleted_old_body_owners(old_bytes, bytes, hunks, changed)
      decisions.each do |decision|
        expression = { byte_start: decision[:byte_start],
                       byte_length: decision[:byte_length] }
        selected << decision[:id] if range_touched?(expression, changed)
        instrumentation_range = decision.dig(:instrumentation, :range)
        selected << decision[:id] if instrumentation_range && range_touched?(instrumentation_range, changed)
      end
      # rubocop:disable-next Metrics/BlockLength -- One AST walk keeps ownership mapping consistent across node kinds.
      walk(parsed.value) do |node|
        if CONTROL_NODES.any? { |type| node.is_a?(type) }
          predicate = node.predicate
          next unless predicate

          predicate = unwrap_predicate(predicate)
          record = decisions.find do |decision|
            decision[:kind] == "boolean" && decision[:byte_start] == predicate.location.start_offset &&
              decision[:byte_length] == predicate.location.length
          end
          next unless record

          selected << record[:id] if range_touched?(predicate.location, changed)
          selected << record[:id] if range_touched?(node.location, changed)
        elsif node.is_a?(Prism::CaseNode) && node.predicate.nil?
          case_records = []
          node.conditions.each do |branch|
            branch.conditions.each do |condition|
              records = decisions.select do |decision|
                decision[:context] == "case_when" && decision[:byte_start] == condition.location.start_offset &&
                  decision[:byte_length] == condition.location.length
              end
              case_records.concat(records)
              next unless branch_body_touched?(branch, changed) ||
                          subjectless_body_deleted?(node, branch, old_body_owners)

              selected.concat(records.map { |record| record[:id] })
            end
          end
          else_clause = node.else_clause
          else_touched = else_clause && (branch_body_touched?(else_clause, changed) ||
            old_body_owners.include?([:else, node.location.start_offset]))
          selected.concat(case_records.map { |record| record[:id] }) if else_touched
        elsif node.is_a?(Prism::CaseNode) || node.is_a?(Prism::CaseMatchNode)
          record = decisions.find do |decision|
            decision[:context] == (node.is_a?(Prism::CaseMatchNode) ? "case_in" : "case") &&
              decision.dig(:instrumentation, :range, :byte_start) == node.location.start_offset
          end
          selected << record[:id] if record && body_touched?(node, changed)
        elsif node.is_a?(Prism::InNode) && (node.pattern.is_a?(Prism::IfNode) || node.pattern.is_a?(Prism::UnlessNode))
          guard = unwrap_predicate(node.pattern.predicate)
          record = decisions.find do |decision|
            decision[:context] == "pattern_guard" && decision[:byte_start] == guard.location.start_offset &&
              decision[:byte_length] == guard.location.length
          end
          body_touched = branch_body_touched?(node, changed) ||
                         old_body_owners.include?([:in, node.location.start_offset,
                                                   guard.location.start_offset, guard.location.length])
          selected << record[:id] if record && body_touched
        end
      end

      selected.uniq
    end

    private

    def unwrap_predicate(node)
      while node.is_a?(Prism::ParenthesesNode)
        body = node.body&.body
        return node unless body&.length == 1

        node = body.first
      end
      node
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Resolves deleted tokens only to surviving branch owners.
    # rubocop:disable-next Metrics/BlockLength -- Old AST ownership is translated against the same hunk set.
    def deleted_old_body_owners(old_bytes, current_bytes, hunks, changed)
      return [] if old_bytes.empty? || changed.none? { |item| item[:old_token_start] }

      parsed = Prism.parse(old_bytes)
      return [] unless parsed.errors.empty?

      owners = []
      walk(parsed.value) do |node|
        if node.is_a?(Prism::CaseNode) && node.predicate.nil?
          branches = node.conditions
          branches.each_with_index do |branch, index|
            next_branch = branches[index + 1]
            boundary = next_branch && branch_keyword_location(next_branch)&.start_offset
            boundary ||= node.else_clause&.else_keyword_loc&.start_offset
            boundary ||= node.end_keyword_loc&.start_offset || node.location.end_offset
            next unless old_branch_body_touched?(branch, boundary, changed)

            current_case_start = map_old_offset(node.location.start_offset, old_bytes, current_bytes, hunks)
            branch.conditions.each do |condition|
              current_condition_start = map_old_offset(condition.location.start_offset, old_bytes, current_bytes, hunks)
              next unless current_case_start && current_condition_start

              owners << [:when, current_case_start, current_condition_start, condition.location.length]
            end
          end
          else_boundary = node.end_keyword_loc&.start_offset || node.location.end_offset
          if node.else_clause && old_else_body_touched?(node.else_clause, else_boundary, changed)
            current_case_start = map_old_offset(node.location.start_offset, old_bytes, current_bytes, hunks)
            owners << [:else, current_case_start] if current_case_start
          end
        elsif node.is_a?(Prism::CaseMatchNode)
          branches = node.conditions
          branches.each_with_index do |branch, index|
            pattern = branch.pattern
            next unless pattern.is_a?(Prism::IfNode) || pattern.is_a?(Prism::UnlessNode)

            next_branch = branches[index + 1]
            boundary = next_branch && branch_keyword_location(next_branch)&.start_offset
            boundary ||= node.else_clause&.else_keyword_loc&.start_offset
            boundary ||= node.end_keyword_loc&.start_offset || node.location.end_offset
            next unless old_branch_body_touched?(branch, boundary, changed)

            guard = unwrap_predicate(pattern.predicate)
            current_branch_start = map_old_offset(branch.location.start_offset, old_bytes, current_bytes, hunks)
            current_guard_start = map_old_offset(guard.location.start_offset, old_bytes, current_bytes, hunks)
            next unless current_branch_start && current_guard_start

            owners << [:in, current_branch_start, current_guard_start, guard.location.length]
          end
        end
      end
      owners
    end

    def branch_keyword_location(branch)
      branch.is_a?(Prism::InNode) ? branch.in_loc : branch.keyword_loc
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Translates unchanged owner byte positions across line hunks.
    def map_old_offset(offset, old_bytes, current_bytes, hunks)
      old_line_start = line_offset(old_bytes, offset)
      old_line = old_bytes.b.byteslice(0, offset).count("\n".b) + 1
      line_delta = 0
      Array(hunks).each do |hunk|
        first = hunk[:old_start]
        last = first + hunk[:old_count]
        if hunk[:old_count].zero?
          line_delta += hunk[:new_count] if old_line > first
          next
        end
        return nil if hunk[:old_count].positive? && old_line >= first && old_line < last

        line_delta += hunk[:new_count] - hunk[:old_count] if old_line >= last
      end
      current_line = old_line + line_delta
      current_line_start = offset_after_line(current_bytes, current_line - 1)
      column = offset - old_line_start
      return nil if current_line_start + column > current_bytes.bytesize

      current_line_start + column
    end

    def line_offset(bytes, offset)
      newline = bytes.b.byteslice(0, offset).rindex("\n".b)
      newline ? newline + 1 : 0
    end

    # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Checks token ownership within one old branch body.
    def old_branch_body_touched?(branch, boundary, changed)
      return false unless boundary

      body_start = branch.statements&.location&.start_offset || branch.location.end_offset
      body_end = [branch.location.end_offset, boundary].min
      return false unless body_end > body_start

      changed.any? do |item|
        item[:old_token_start] && item[:old_token_start] >= body_start && item[:old_token_start] < body_end
      end
    end

    def old_else_body_touched?(branch, boundary, changed)
      body_start = branch.else_keyword_loc.end_offset
      changed.any? do |item|
        item[:old_token_start] && item[:old_token_start] >= body_start && item[:old_token_start] < boundary
      end
    end

    def subjectless_body_deleted?(case_node, branch, old_body_owners)
      branch.conditions.any? do |condition|
        old_body_owners.include?([:when, case_node.location.start_offset,
                                  condition.location.start_offset, condition.location.length])
      end
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Token comparison retains lexer context for heredocs and strings.
    def changed_locations(hunks, old_bytes, bytes)
      changed = []
      old_tokens = Prism.lex(old_bytes).value
      current_tokens = Prism.lex(bytes).value
      Array(hunks).each do |hunk|
        old_range = (hunk[:old_start]...(hunk[:old_start] + hunk[:old_count]))
        new_range = (hunk[:new_start]...(hunk[:new_start] + hunk[:new_count]))
        old_hunk_tokens = semantic_tokens(old_tokens, old_range)
        new_hunk_tokens = semantic_tokens(current_tokens, new_range)
        next unless meaningful_tokens?(old_hunk_tokens) || meaningful_tokens?(new_hunk_tokens)
        next if old_hunk_tokens == new_hunk_tokens

        count = hunk[:new_count]
        start = hunk[:new_start]
        old_token_start = first_meaningful_token_start(old_tokens, old_range)
        if count.positive?
          code_lines = (start...(start + count)).filter_map do |line|
            line_range(bytes, line).merge(old_token_start: old_token_start) if code_line?(current_tokens, line)
          end
          if code_lines.empty?
            changed << { anchor: offset_after_line(bytes, start - 1), old_token_start: old_token_start }
          else
            changed.concat(code_lines)
          end
        else
          changed << { anchor: offset_after_line(bytes, start), old_token_start: old_token_start }
        end
      end
      changed
    end

    def code_line?(tokens, line)
      tokens.any? do |token, _state|
        line.between?(token.location.start_line, token.location.end_line) &&
          !%i[COMMENT NEWLINE IGNORED_NEWLINE EOF].include?(token.type)
      end
    end

    def semantic_tokens(tokens, lines)
      tokens.filter_map do |token, _state|
        next unless token.location.start_line < lines.end && token.location.end_line >= lines.begin

        if token.type == :COMMENT
          next unless token.value.end_with?("\n")

          next [:NEWLINE, "\n"]
        end
        next if %i[IGNORED_NEWLINE EOF].include?(token.type)

        [token.type, token.value]
      end
    end

    def meaningful_tokens?(tokens)
      tokens.any? { |type, _value| !%i[COMMENT NEWLINE IGNORED_NEWLINE EOF].include?(type) }
    end

    # rubocop:disable-next Style/HashEachMethods -- Prism.lex returns token/state pairs in an Array.
    def first_meaningful_token_start(tokens, lines)
      tokens.each do |token, _state|
        next unless token.location.start_line >= lines.begin && token.location.start_line < lines.end
        next if %i[COMMENT NEWLINE IGNORED_NEWLINE EOF].include?(token.type)

        return token.location.start_offset
      end
      nil
    end

    def offset_after_line(bytes, line)
      return 0 if line.zero?

      bytes.lines.first(line).sum(&:bytesize)
    end

    def line_range(bytes, line)
      start_offset = offset_after_line(bytes, line - 1)
      line_bytes = bytes.lines[line - 1].to_s
      { start_offset: start_offset, end_offset: start_offset + line_bytes.bytesize }
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Handles byte ranges and deletion anchors consistently.
    def range_touched?(location, changed)
      if location.is_a?(Hash)
        start_offset = location[:byte_start]
        end_offset = start_offset + location[:byte_length]
      else
        start_offset = location.start_offset
        end_offset = location.end_offset
      end
      changed.any? do |item|
        if item.key?(:anchor)
          item[:anchor] > start_offset && item[:anchor] < end_offset
        else
          item[:start_offset] < end_offset && item[:end_offset] > start_offset
        end
      end
    end

    def body_touched?(node, changed)
      body_locations(node).any? do |location|
        location && changed.any? do |item|
          if item.key?(:anchor)
            item[:anchor] > location.start_offset && item[:anchor] < location.end_offset
          else
            item[:start_offset] < location.end_offset && item[:end_offset] > location.start_offset
          end
        end
      end
    end

    def branch_body_touched?(branch, changed)
      location = branch.statements&.location
      return false unless location

      changed.any? do |item|
        if item.key?(:anchor)
          item[:anchor] > location.start_offset && item[:anchor] < location.end_offset
        else
          item[:start_offset] < location.end_offset && item[:end_offset] > location.start_offset
        end
      end
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Metadata range shapes vary by Prism node family.
    def body_locations(node)
      if CONTROL_NODES.any? { |type| node.is_a?(type) }
        [node.statements&.location, node.subsequent&.statements&.location]
      elsif node.is_a?(Prism::CaseNode) || node.is_a?(Prism::CaseMatchNode)
        node.conditions.map { |branch| branch.statements&.location } + [node.else_clause&.statements&.location]
      else
        []
      end
    end

    def walk(node, &block)
      return unless node

      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end
  end
end
