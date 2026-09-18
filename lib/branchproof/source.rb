# frozen_string_literal: true

require "digest"
require "pathname"
require "prism"
require_relative "decision_syntax"
require_relative "iteration_syntax"
require_relative "exception_syntax"
require_relative "default_syntax"
require_relative "value_syntax"
require_relative "constraints"

module Branchproof
  # Inventories supported condition and decision occurrences from Ruby files.
  class Source
    include DecisionSyntax
    # Contextual syntax modules are layered after the baseline classifier so
    # each can extend discovery without coupling this walker to every syntax
    # family. Additional modules can follow the same seam.
    include IterationSyntax
    include ExceptionSyntax
    prepend DefaultSyntax
    prepend ValueSyntax

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
      absolute_path = File.expand_path(path)
      relative_path = relative(path)
      bytes = File.binread(path)
      parsed = Prism.parse(bytes)
      encoding = source_encoding(bytes, parsed)
      digest = Digest::SHA256.hexdigest(bytes)
      source_id = Records.source_id(relative_path: relative_path, digest: digest, encoding: encoding)
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
      Records.build(source_id: source_id, relative_path: relative_path, absolute_path: absolute_path,
                    real_path: File.realpath(path), digest: digest, encoding: encoding,
                    original_bytes: bytes, decisions: decisions, diagnostics: diagnostics)
    rescue SystemCallError => e
      Records.build(source_id: nil, relative_path: relative_path, absolute_path: absolute_path,
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

    # Walks the whole program AST exactly once, sorting every node into the
    # buckets the two classification phases below need. Phase one (decision
    # and case-when nodes) must run to completion before phase two (bare
    # boolean/pattern nodes) because phase two skips nodes phase one already
    # inventoried via mark_semantic_boolean_nodes.
    def collect_ast_nodes(program)
      defined_ranges = []
      guard_patterns = {}.compare_by_identity
      phase_one_nodes = []
      phase_two_nodes = []
      flow_nodes = []

      walk_skipping_defined_operands(program) do |node|
        if node.is_a?(Prism::DefinedNode)
          defined_ranges << node.location
        elsif node.is_a?(Prism::InNode)
          pattern = node.pattern
          guard_patterns[pattern] = true if pattern.is_a?(Prism::IfNode) || pattern.is_a?(Prism::UnlessNode)
        end
        phase_one_nodes << node if decision_node?(node) || subjectless_case?(node)
        phase_two_nodes << node if boolean_node?(node) || node.is_a?(Prism::MatchPredicateNode) ||
                                   node.is_a?(Prism::DefinedNode)
        flow_nodes << node if flow_decision_node?(node)
      end

      { defined_ranges: defined_ranges, guard_patterns: guard_patterns, phase_one_nodes: phase_one_nodes,
        phase_two_nodes: phase_two_nodes, flow_nodes: flow_nodes }
    end

    def decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8")
      specs = []
      inventoried_boolean_nodes = {}.compare_by_identity
      collected = collect_ast_nodes(program)
      defined_ranges = collected[:defined_ranges]
      guard_patterns = collected[:guard_patterns]

      collected[:phase_one_nodes].each do |node|
        if decision_node?(node)
          predicate = node.predicate
          next unless predicate

          predicate = unwrap_predicate(predicate)
          context = guard_patterns[node] ? "pattern_guard" : decision_context(node, bytes)
          specs << { node: node, predicate: predicate, context: context }
          mark_semantic_boolean_nodes(predicate, inventoried_boolean_nodes)
        else
          conditions_for(node).each do |when_node|
            conditions_for(when_node).each do |predicate|
              predicate = unwrap_predicate(predicate)
              specs << { node: when_node, predicate: predicate, context: "case_when" }
              mark_semantic_boolean_nodes(predicate, inventoried_boolean_nodes)
            end
          end
        end
      end

      # Boolean expressions nested in an atomic expression (for example, a call
      # argument) are separate decisions when tree_for did not decompose them.
      collected[:phase_two_nodes].each do |node|
        next if inventoried_boolean_nodes[node]
        next if within_defined_expression?(node, defined_ranges) && !node.is_a?(Prism::DefinedNode)

        context = if node.is_a?(Prism::MatchPredicateNode)
                    "pattern_in"
                  elsif node.is_a?(Prism::DefinedNode)
                    "defined"
                  else
                    "short_circuit"
                  end
        specs << { node: nil, predicate: node, context: context,
                   additional_reasons: [] }
        mark_semantic_boolean_nodes(node, inventoried_boolean_nodes)
      end

      ordered_specs = specs.each_with_index.sort_by do |(spec, index)|
        [spec[:predicate].location.start_offset, index]
      end.map(&:first)
      seen_ranges = {}
      boolean_decisions = ordered_specs.filter_map do |spec|
        predicate = spec[:predicate]
        range = [predicate.location.start_offset, predicate.location.length]
        next if seen_ranges[range]

        seen_ranges[range] = true
        build_decision(spec[:node], bytes, source_id, file_reasons, encoding,
                       predicate: predicate, context: spec[:context],
                       additional_reasons: spec[:additional_reasons] || [])
      end
      boolean_decisions + flow_decisions_for(program, bytes, source_id, file_reasons, encoding,
                                             defined_ranges: defined_ranges, nodes: collected[:flow_nodes])
    end

    def flow_decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8",
                           defined_ranges: nil, nodes: nil)
      defined_ranges ||= collect_defined_ranges(program)

      nodes ||= collect_flow_decision_nodes(program)
      nodes = nodes.reject { |node| within_defined_expression?(node, defined_ranges) }
      super(program, bytes, source_id, file_reasons, encoding, nodes: nodes)
    end

    def collect_defined_ranges(program)
      defined_ranges = []
      walk(program) { |node| defined_ranges << node.location if node.is_a?(Prism::DefinedNode) }
      defined_ranges
    end

    def range_within_defined_expression?(decision, defined_ranges)
      start_offset = decision[:byte_start]
      offsets_within_defined_expression?(start_offset, start_offset + decision[:byte_length], defined_ranges)
    end

    def walk(node, &block)
      yield node
      node.child_nodes.each { |child| walk(child, &block) if child }
    end

    def decision_node?(node)
      node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode) ||
        node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode)
    end

    def boolean_node?(node)
      node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)
    end

    def subjectless_case?(node)
      node.is_a?(Prism::CaseNode) && node.predicate.nil?
    end

    def conditions_for(node)
      conditions = node.conditions
      if conditions.is_a?(Array)
        conditions
      else
        (conditions.respond_to?(:body) ? conditions.body : [])
      end
    end

    def decision_context(node, bytes)
      return "unless" if node.is_a?(Prism::UnlessNode)
      return "while" if node.is_a?(Prism::WhileNode)
      return "until" if node.is_a?(Prism::UntilNode)
      return "ternary" if node.if_keyword_loc.nil?

      token = bytes.byteslice(node.if_keyword_loc.start_offset, node.if_keyword_loc.length)
      token == "elsif" ? "elsif" : "if"
    end

    def build_decision(node, bytes, source_id, file_reasons = [], encoding = "UTF-8", predicate: nil,
                       context: nil, additional_reasons: [])
      original_predicate = node.respond_to?(:predicate) ? node.predicate : nil
      predicate ||= unwrap_predicate(original_predicate)
      context ||= decision_context(node, bytes)
      leaves = []
      tree = tree_for(predicate, bytes, leaves)
      decision_constraint_safe = constraint_safe_expression?(predicate)
      start_offset = predicate.location.start_offset
      length = predicate.location.length
      opaque_ranges = leaves.filter_map { |leaf| leaf.delete(:_opaque_range) }
      conditions = leaves.each_with_index.map do |leaf, index|
        expression = text_value(leaf.delete(:_expression), "UTF-8")
        location = leaf.delete(:_location)
        literal_truth = leaf.delete(:_literal_truth)
        constraint = leaf.delete(:_constraint)
        constraint_safe = leaf.delete(:_constraint_safe)
        contextual = leaf.delete(:_contextual)
        condition = Records.build(id: nil, index: index, byte_start: location.start_offset,
                                  byte_length: location.length,
                                  line: location.start_line, column: location.start_column,
                                  expression: expression, literal_truth: literal_truth, coupling: "unknown",
                                  constraint: constraint,
                                  constraint_safe: decision_constraint_safe && constraint_safe == true)
        contextual ? condition.merge(contextual: contextual) : condition
      end
      decision_id = Records.decision_id(source_id: source_id, context: context, byte_start: start_offset,
                                        byte_length: length, tree: tree)
      conditions = conditions.map do |condition|
        condition.merge(id: Records.condition_id(decision_id, condition[:index]))
      end
      reasons = unsupported_reasons(predicate, bytes) + additional_reasons + file_reasons
      reasons << "unsupported_case_splat" if predicate.is_a?(Prism::SplatNode)
      reasons << "unsupported_control_expression" if ambiguous_parentheses?(original_predicate)
      reasons << "condition_limit_exceeded" if conditions.length > @limits[:conditions_per_decision]
      discovered_condition_count = conditions.length
      if discovered_condition_count > @limits[:conditions_per_decision]
        conditions = conditions.first(@limits[:conditions_per_decision])
        tree = nil
      end
      support = reasons.empty? ? "SUPPORTED" : "UNSUPPORTED"
      expression = text_value(bytes.byteslice(predicate.location.start_offset, predicate.location.length), encoding)
      Records.build(id: decision_id, source_id: source_id, kind: "boolean", context: context,
                    byte_start: start_offset, byte_length: length,
                    line: predicate.location.start_line, column: predicate.location.start_column,
                    expression: expression,
                    tree: tree,
                    conditions: conditions, discovered_condition_count: discovered_condition_count,
                    support_status: support, support_reasons: reasons.uniq, opaque_ranges: opaque_ranges)
    end

    def within_defined_expression?(node, defined_ranges)
      location = node.location
      offsets_within_defined_expression?(location.start_offset, location.end_offset, defined_ranges)
    end

    def offsets_within_defined_expression?(start_offset, end_offset, defined_ranges)
      defined_ranges.any? do |defined_location|
        defined_location.start_offset <= start_offset && defined_location.end_offset >= end_offset
      end
    end

    def mark_semantic_boolean_nodes(node, inventoried_boolean_nodes)
      node = unwrap_predicate(node)
      case node
      when Prism::AndNode, Prism::OrNode
        inventoried_boolean_nodes[node] = true
        mark_semantic_boolean_nodes(node.left, inventoried_boolean_nodes)
        mark_semantic_boolean_nodes(node.right, inventoried_boolean_nodes)
      when Prism::DefinedNode, Prism::MatchPredicateNode
        inventoried_boolean_nodes[node] = true
      when Prism::CallNode
        mark_semantic_boolean_nodes(node.receiver, inventoried_boolean_nodes) if unary_not?(node)
      end
    end

    def tree_for(node, bytes, leaves)
      node = unwrap_predicate(node)
      case node
      when Prism::AndNode
        Records.build(type: :and, left: tree_for(node.left, bytes, leaves), right: tree_for(node.right, bytes, leaves))
      when Prism::OrNode
        Records.build(type: :or, left: tree_for(node.left, bytes, leaves), right: tree_for(node.right, bytes, leaves))
      when Prism::CallNode
        if unary_not?(node)
          Records.build(type: :not, child: tree_for(node.receiver, bytes, leaves))
        else
          leaf_for(node, bytes, leaves)
        end
      else
        leaf_for(node, bytes, leaves)
      end
    end

    def leaf_for(node, bytes, leaves)
      location = node.location
      leaf = {
        _expression: bytes.byteslice(location.start_offset, location.length), _location: location,
        _literal_truth: literal_truth(node),
        _constraint: (constraint = Constraints.for_node(node)),
        _constraint_safe: safe_constraint_node?(constraint),
        _opaque_range: if node.is_a?(Prism::CallNode) && node.name == :!
                         { start: location.start_offset, length: location.length }
                       end
      }
      leaf[:_contextual] = "implicit_regexp" if node.is_a?(Prism::MatchLastLineNode) ||
                                                node.is_a?(Prism::InterpolatedMatchLastLineNode)
      leaf[:_contextual] = "flip_flop" if node.is_a?(Prism::FlipFlopNode)
      leaves << leaf
      Records.build(type: :atom, index: leaves.length - 1)
    end

    # Source-derived comparisons are deliberately untrusted. Ruby permits
    # mutation between leaves and user-defined operators, so only repeated
    # truthiness reads of local variables in an entirely side-effect-free
    # decision may be used by the table solver.
    def constraint_safe_expression?(node)
      node = unwrap_predicate(node)
      case node
      when Prism::AndNode, Prism::OrNode
        constraint_safe_expression?(node.left) && constraint_safe_expression?(node.right)
      when Prism::LocalVariableReadNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::SymbolNode, Prism::StringNode
        true
      else
        false
      end
    end

    def safe_constraint_node?(constraint)
      constraint && constraint[:operator] == "truthy" && constraint[:subject][:kind] == "local"
    end

    def unary_not?(node)
      node.is_a?(Prism::CallNode) && node.name == :! && node.receiver && node.call_operator_loc.nil?
    end

    def literal_truth(node)
      return true if node.is_a?(Prism::TrueNode)
      return false if node.is_a?(Prism::FalseNode) || node.is_a?(Prism::NilNode)

      nil
    end

    def unsupported_reasons(predicate, bytes)
      reasons = []
      walk_skipping_defined_operands(predicate) do |node|
        reasons << "unsupported_heredoc" if node.respond_to?(:opening_loc) && node.opening_loc &&
                                            bytes.byteslice(node.opening_loc.start_offset,
                                                            node.opening_loc.length).start_with?("<<")
      end
      reasons
    end

    def walk_skipping_defined_operands(node, &block)
      yield node
      return if node.is_a?(Prism::DefinedNode)

      node.child_nodes.each { |child| walk_skipping_defined_operands(child, &block) if child }
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
