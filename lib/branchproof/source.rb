# frozen_string_literal: true

require "digest"
require "pathname"
require "prism"

module Branchproof
  # Inventories supported condition and decision occurrences from Ruby files.
  class Source
    attr_reader :root, :limits

    def initialize(root:, limits:)
      raise ArgumentError, "root must be an absolute path" unless root.is_a?(String) && Pathname.new(root).absolute?
      raise ArgumentError, "limits must be a Limits record" unless limits.is_a?(Hash)

      @root = File.realpath(root)
      @limits = Limits.normalize(limits)
    end

    def inventory(paths:)
      raise ArgumentError, "paths must be an Array" unless paths.is_a?(Array)
      raise ArgumentError, "paths must contain only Strings" unless paths.all?(String)

      units = paths.flat_map { |path| expand(path) }.uniq.sort.filter_map { |path| read_unit(path) }
      decisions = units.flat_map { |unit| unit[:decisions] }
                       .sort_by { |decision| [decision[:source_id], decision[:byte_start]] }
      diagnostics = units.flat_map { |unit| unit[:diagnostics] }
      diagnostics += decisions.flat_map do |decision|
        decision[:support_reasons].map do |reason|
          Records.diagnostic(code: reason, message: "Unsupported source syntax: #{reason}",
                             source_id: decision[:source_id], decision_id: decision[:id])
        end
      end
      supported = decisions.count { |decision| decision[:support_status] == "SUPPORTED" }
      opaque = decisions.sum { |decision| decision[:opaque_ranges].length }
      limited = diagnostics.count { |diagnostic| diagnostic[:code] == "limit_reached" }
      scope = Records.build(discovered: decisions.length, supported: supported,
                            unsupported: decisions.length - supported, opaque: opaque,
                            unexecuted: 0, completed: 0, aborted: 0, unattributed: 0, limited: limited)
      Records.build(root: @root, source_units: units.map { |unit| unit.except(:diagnostics) },
                    decisions: decisions, diagnostics: diagnostics, scope: scope)
    end

    private

    def expand(path)
      pattern = File.expand_path(path.to_s, @root)
      matches = Dir[pattern].select { |candidate| File.file?(candidate) }
      matches = [pattern] if matches.empty? && File.file?(pattern)
      matches.filter_map do |candidate|
        File.realpath(candidate)
      rescue SystemCallError
        nil
      end
    end

    def read_unit(path)
      bytes = File.binread(path)
      parsed = Prism.parse(bytes)
      encoding = source_encoding(bytes, parsed)
      source_id = Records.source_id(relative_path: relative(path), digest: Digest::SHA256.hexdigest(bytes),
                                    encoding: encoding)
      diagnostics = parsed.errors.map do |error|
        Records.diagnostic(code: "parse_error", severity: "error", message: error.message, source_id: source_id,
                           details: { byte_start: error.location.start_offset, byte_length: error.location.length })
      end
      if parsed.respond_to?(:data_loc) && parsed.data_loc
        diagnostics << Records.diagnostic(
          code: "unsupported_data_section",
          message: "__END__ data is outside the supported source scope",
          source_id: source_id
        )
      end
      file_reasons = []
      file_reasons << "unsupported_data_section" if parsed.respond_to?(:data_loc) && parsed.data_loc
      file_reasons << "parse_error" unless parsed.errors.empty?
      decisions = parsed.value ? decisions_for(parsed.value, bytes, source_id, file_reasons, encoding) : []
      Records.build(source_id: source_id, relative_path: relative(path), absolute_path: File.expand_path(path),
                    real_path: File.realpath(path), digest: Digest::SHA256.hexdigest(bytes), encoding: encoding,
                    original_bytes: bytes, decisions: decisions, diagnostics: diagnostics)
    rescue SystemCallError => e
      Records.build(source_id: nil, relative_path: relative(path), absolute_path: File.expand_path(path),
                    real_path: nil, digest: nil, encoding: nil, original_bytes: nil, decisions: [],
                    diagnostics: [Records.diagnostic(code: "source_unreadable", severity: "error", message: e.message)])
    end

    def source_encoding(bytes, parsed)
      source = parsed.source
      return source.encoding.name if source.respond_to?(:encoding)

      header = bytes.lines.first(2).join
      match = header.match(/coding\s*[:=]\s*([A-Za-z0-9._-]+)/)
      return Encoding.find(match[1]).name if match

      Encoding::UTF_8.name
    rescue ArgumentError
      Encoding::UTF_8.name
    end

    def decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8")
      nodes = []
      walk(program) { |node| nodes << node if decision_node?(node) }
      nodes.sort_by { |node| node.location.start_offset }.map.with_index do |node, _|
        build_decision(node, bytes, source_id, file_reasons, encoding)
      end
    end

    def walk(node, &block)
      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end

    def decision_node?(node)
      node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
    end

    def build_decision(node, bytes, source_id, file_reasons = [], encoding = "UTF-8")
      predicate = unwrap_predicate(node.predicate)
      leaves = []
      tree = tree_for(predicate, bytes, leaves)
      start_offset = predicate.location.start_offset
      length = predicate.location.length
      context = if node.is_a?(Prism::UnlessNode)
                  "unless"
                elsif node.if_keyword_loc.nil?
                  "ternary"
                else
                  token = bytes.byteslice(node.if_keyword_loc.start_offset, node.if_keyword_loc.length)
                  token == "elsif" ? "elsif" : "if"
                end
      opaque_ranges = leaves.filter_map { |leaf| leaf.delete(:_opaque_range) }
      conditions = leaves.each_with_index.map do |leaf, index|
        expression = text_value(leaf.delete(:_expression), "UTF-8")
        location = leaf.delete(:_location)
        literal_truth = leaf.delete(:_literal_truth)
        Records.build(id: nil, index: index, byte_start: location.start_offset, byte_length: location.length,
                      expression: expression, literal_truth: literal_truth, coupling: "unknown")
      end
      decision_id = Records.decision_id(source_id: source_id, context: context, byte_start: start_offset,
                                        byte_length: length, tree: tree)
      conditions = conditions.map do |condition|
        condition.merge(id: Records.condition_id(decision_id, condition[:index]))
      end
      reasons = unsupported_reasons(predicate, bytes) + file_reasons
      reasons << "unsupported_control_expression" if ambiguous_parentheses?(node.predicate)
      reasons << "condition_limit_exceeded" if conditions.length > @limits[:conditions_per_decision]
      discovered_condition_count = conditions.length
      if discovered_condition_count > @limits[:conditions_per_decision]
        conditions = conditions.first(@limits[:conditions_per_decision])
        tree = nil
      end
      support = reasons.empty? ? "SUPPORTED" : "UNSUPPORTED"
      expression = text_value(bytes.byteslice(predicate.location.start_offset, predicate.location.length), encoding)
      Records.build(id: decision_id, source_id: source_id, context: context, byte_start: start_offset,
                    byte_length: length, line: predicate.location.start_line, column: predicate.location.start_column,
                    expression: expression,
                    tree: tree,
                    conditions: conditions, discovered_condition_count: discovered_condition_count,
                    support_status: support, support_reasons: reasons.uniq, opaque_ranges: opaque_ranges)
    end

    def tree_for(node, bytes, leaves)
      node = unwrap_predicate(node)
      case node
      when Prism::AndNode
        Records.build(type: :and, left: tree_for(node.left, bytes, leaves), right: tree_for(node.right, bytes, leaves))
      when Prism::OrNode
        Records.build(type: :or, left: tree_for(node.left, bytes, leaves), right: tree_for(node.right, bytes, leaves))
      else
        location = node.location
        leaf = {
          _expression: bytes.byteslice(location.start_offset, location.length), _location: location,
          _literal_truth: literal_truth(node),
          _opaque_range: opaque?(node) ? { start: location.start_offset, length: location.length } : nil
        }
        leaves << leaf
        Records.build(type: :atom, index: leaves.length - 1)
      end
    end

    def literal_truth(node)
      return true if node.is_a?(Prism::TrueNode)
      return false if node.is_a?(Prism::FalseNode) || node.is_a?(Prism::NilNode)

      nil
    end

    def opaque?(node)
      node.is_a?(Prism::CallNode) && node.name == :!
    end

    def unsupported_reasons(predicate, bytes)
      reasons = []
      walk(predicate) do |node|
        if node.is_a?(Prism::MatchLastLineNode) || node.is_a?(Prism::InterpolatedMatchLastLineNode)
          reasons << "unsupported_implicit_regexp"
        end
        reasons << "unsupported_flip_flop" if node.is_a?(Prism::FlipFlopNode)
        reasons << "unsupported_heredoc" if node.respond_to?(:opening_loc) && node.opening_loc &&
                                            bytes.byteslice(node.opening_loc.start_offset,
                                                            node.opening_loc.length).start_with?("<<")
        if (node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)) && node.respond_to?(:operator_loc)
          operator = bytes.byteslice(node.operator_loc.start_offset, node.operator_loc.length)
          reasons << "unsupported_keyword_boolean" if %w[and or].include?(operator)
        end
      end
      reasons
    end

    def unwrap_predicate(node)
      while node.is_a?(Prism::ParenthesesNode)
        statements = node.body
        body = statements&.body
        return node unless body&.length == 1

        node = body.first
      end
      node
    end

    def ambiguous_parentheses?(node)
      return false unless node.is_a?(Prism::ParenthesesNode)

      body = node.body&.body
      !body || body.length != 1
    end

    def text_value(value, encoding)
      value.dup.force_encoding(encoding).encode("UTF-8")
    rescue EncodingError
      value.dup.force_encoding(Encoding::BINARY)
    end

    def relative(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@root)).to_s
    end
  end
end
