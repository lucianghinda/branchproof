# frozen_string_literal: true

require "prism"

module Branchproof
  # Normalizes simple atomic conditions into subject/operator/value records and
  # decides, conservatively, whether a set of required condition truths can hold
  # at the same time.
  #
  # The module never evaluates application code. It only inspects the syntax of
  # a condition, and it answers "contradictory" only when the contradiction
  # follows from the normalized constraints alone. Every other shape stays
  # unrepresented, which leaves the owning decision-table rule reachability
  # +unknown+.
  module Constraints
    VERSION = 1

    NUMERIC_OPERATORS = %w[< <= > >=].freeze
    COMPARISON_OPERATORS = %w[< <= > >= == !=].freeze
    OPERATORS = (COMPARISON_OPERATORS + ["truthy"]).freeze
    FLIPPED = { "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<=", "==" => "==", "!=" => "!=" }.freeze
    NUMERIC_TYPES = %w[integer float].freeze
    FALSEY_TYPES = %w[nil false].freeze
    LITERAL_TYPES = %w[integer float symbol nil true false].freeze
    SUBJECT_KINDS = %w[local instance class global constant].freeze
    REASONS = %w[
      conflicting_numeric_bounds conflicting_equalities equality_outside_numeric_range
      nil_conflict boolean_literal_conflict
    ].freeze
    REASON_MESSAGES = {
      "conflicting_numeric_bounds" => "conflicting numeric bounds",
      "conflicting_equalities" => "conflicting equalities",
      "equality_outside_numeric_range" => "required equality is outside the required numeric range",
      "nil_conflict" => "conflicting nil requirements",
      "boolean_literal_conflict" => "conflicting Boolean literal requirements"
    }.freeze

    # Accumulates the constraints one decision-table rule requires and reports
    # the first proven contradiction. Subjects never interact with each other.
    class Solver
      def initialize
        @subjects = {}
      end

      # Returns a reason code when the rule became unsatisfiable, otherwise nil.
      def add(constraint, truth)
        constraint = Constraints.symbolize(constraint)
        return nil unless Constraints.usable?(constraint)

        state = (@subjects[Constraints.subject_key(constraint[:subject])] ||= new_state)
        apply(state, constraint[:operator].to_s, constraint[:literal], truth ? true : false)
      end

      private

      def new_state
        { lower: nil, upper: nil, equality: nil, exclusions: [], nil_required: nil, truthy: nil }
      end

      def apply(state, operator, literal, truth)
        case operator
        when "truthy" then truth ? require_truthy(state) : require_falsey(state)
        when "==" then truth ? require_equal(state, literal) : exclude(state, literal)
        when "!=" then truth ? exclude(state, literal) : require_equal(state, literal)
        when "<" then truth ? upper(state, literal, false) : lower(state, literal, true)
        when "<=" then truth ? upper(state, literal, true) : lower(state, literal, false)
        when ">" then truth ? lower(state, literal, false) : upper(state, literal, true)
        when ">=" then truth ? lower(state, literal, true) : upper(state, literal, false)
        end
      end

      def require_equal(state, literal)
        type = literal[:type].to_s
        # A nil or truthiness clash is reported before a plain equality clash so
        # the reason code names the most specific contradiction.
        reason = equality_truthiness_conflict(state, type)
        return reason if reason
        return "conflicting_equalities" if state[:equality] && !Constraints.same_literal?(state[:equality], literal)
        return "conflicting_equalities" if state[:exclusions].any? { |item| Constraints.same_literal?(item, literal) }

        state[:equality] = literal
        state[:nil_required] = type == "nil"
        return "equality_outside_numeric_range" if Constraints.numeric?(literal) && !within_bounds?(state,
                                                                                                    literal[:value])

        nil
      end

      def equality_truthiness_conflict(state, type)
        if type == "nil"
          return "nil_conflict" if state[:nil_required] == false || state[:truthy] == true
        elsif state[:nil_required] == true
          return "nil_conflict"
        end
        return "boolean_literal_conflict" if state[:truthy] == true && type == "false"
        return "boolean_literal_conflict" if state[:truthy] == false && !FALSEY_TYPES.include?(type)

        nil
      end

      def exclude(state, literal)
        if literal[:type].to_s == "nil"
          return "nil_conflict" if state[:nil_required] == true
          return "nil_conflict" if state[:equality] && state[:equality][:type].to_s == "nil"

          state[:nil_required] = false
        elsif state[:equality] && Constraints.same_literal?(state[:equality], literal)
          return "conflicting_equalities"
        end
        state[:exclusions] << literal unless state[:exclusions].any? { |item| Constraints.same_literal?(item, literal) }
        nil
      end

      def require_truthy(state)
        return "boolean_literal_conflict" if state[:truthy] == false
        return "nil_conflict" if state[:nil_required] == true
        return "nil_conflict" if state[:equality] && state[:equality][:type].to_s == "nil"
        return "boolean_literal_conflict" if state[:equality] && state[:equality][:type].to_s == "false"

        state[:truthy] = true
        state[:nil_required] = false
        nil
      end

      def require_falsey(state)
        return "boolean_literal_conflict" if state[:truthy] == true
        return "boolean_literal_conflict" if state[:equality] && !FALSEY_TYPES.include?(state[:equality][:type].to_s)

        state[:truthy] = false
        nil
      end

      def lower(state, literal, inclusive)
        return nil unless Constraints.numeric?(literal)

        current = state[:lower]
        value = literal[:value]
        if current.nil? || value > current[:value] || (value == current[:value] && !inclusive)
          state[:lower] = { value: value, inclusive: inclusive }
        end
        bounds_conflict(state)
      end

      def upper(state, literal, inclusive)
        return nil unless Constraints.numeric?(literal)

        current = state[:upper]
        value = literal[:value]
        if current.nil? || value < current[:value] || (value == current[:value] && !inclusive)
          state[:upper] = { value: value, inclusive: inclusive }
        end
        bounds_conflict(state)
      end

      def bounds_conflict(state)
        low = state[:lower]
        high = state[:upper]
        if low && high
          return "conflicting_numeric_bounds" if low[:value] > high[:value]
          return "conflicting_numeric_bounds" if low[:value] == high[:value] && !(low[:inclusive] && high[:inclusive])
        end
        equality = state[:equality]
        return nil unless equality && Constraints.numeric?(equality) && !within_bounds?(state, equality[:value])

        "equality_outside_numeric_range"
      end

      def within_bounds?(state, value)
        low = state[:lower]
        high = state[:upper]
        return false if low && (low[:inclusive] ? value < low[:value] : value <= low[:value])
        return false if high && (high[:inclusive] ? value > high[:value] : value >= high[:value])

        true
      end
    end

    module_function

    # Derives the normalized constraint of one atomic condition, or nil when the
    # expression is outside the supported vocabulary.
    def for_node(node)
      return nil unless node.is_a?(Prism::Node)

      subject = subject_for(node)
      return { subject: subject, operator: "truthy", literal: nil } if subject
      return nil unless simple_call?(node)

      name = node.name.to_s
      return nil_constraint(node) if name == "nil?"
      return nil unless FLIPPED.key?(name)

      comparison_constraint(node, name)
    end

    def comparison_constraint(node, name)
      argument = single_argument(node)
      return nil unless argument

      subject = subject_for(node.receiver)
      if subject
        literal = literal_for(argument)
        operator = name
      else
        subject = subject_for(argument)
        literal = subject && literal_for(node.receiver)
        operator = FLIPPED.fetch(name)
      end
      return nil unless subject && literal
      return nil if NUMERIC_OPERATORS.include?(operator) && !NUMERIC_TYPES.include?(literal[:type])

      { subject: subject, operator: operator, literal: literal }
    end

    def nil_constraint(node)
      return nil unless node.arguments.nil?

      subject = subject_for(node.receiver)
      return nil unless subject

      { subject: subject, operator: "==", literal: { type: "nil", value: nil } }
    end

    def simple_call?(node)
      node.is_a?(Prism::CallNode) && !node.safe_navigation? && node.block.nil?
    end

    def single_argument(node)
      arguments = node.arguments&.arguments
      return nil unless arguments && arguments.length == 1

      argument = arguments.first
      return nil if argument.is_a?(Prism::SplatNode) || argument.is_a?(Prism::KeywordHashNode) ||
                    argument.is_a?(Prism::BlockArgumentNode)

      argument
    end

    # Only unambiguously identifiable storage locations become subjects.
    # Method-call receivers stay unsupported: a repeated call may return a
    # different value or have side effects (see the v1 constraint scope).
    def subject_for(node)
      case node
      when Prism::LocalVariableReadNode then { kind: "local", name: node.name.to_s }
      when Prism::InstanceVariableReadNode then { kind: "instance", name: node.name.to_s }
      when Prism::ClassVariableReadNode then { kind: "class", name: node.name.to_s }
      when Prism::GlobalVariableReadNode then { kind: "global", name: node.name.to_s }
      when Prism::ConstantReadNode then { kind: "constant", name: node.name.to_s }
      end
    end

    # String equality stays unsupported in v1 so that encoding and mutability
    # questions cannot turn into an impossibility claim.
    def literal_for(node)
      case node
      when Prism::IntegerNode then { type: "integer", value: node.value }
      when Prism::FloatNode then { type: "float", value: node.value }
      when Prism::SymbolNode then { type: "symbol", value: node.unescaped.to_s }
      when Prism::NilNode then { type: "nil", value: nil }
      when Prism::TrueNode then { type: "true", value: true }
      when Prism::FalseNode then { type: "false", value: false }
      end
    end

    def usable?(constraint)
      return false unless constraint.is_a?(Hash)

      subject = symbolize(constraint[:subject])
      operator = constraint[:operator].to_s
      return false unless subject.is_a?(Hash) && SUBJECT_KINDS.include?(subject[:kind].to_s)
      return false if subject[:name].to_s.empty?
      return false unless OPERATORS.include?(operator)
      return true if operator == "truthy"

      literal = symbolize(constraint[:literal])
      return false unless literal.is_a?(Hash) && LITERAL_TYPES.include?(literal[:type].to_s)
      return false if NUMERIC_OPERATORS.include?(operator) && !NUMERIC_TYPES.include?(literal[:type].to_s)

      true
    end

    def subject_key(subject)
      subject = symbolize(subject)
      [subject[:kind].to_s, subject[:name].to_s]
    end

    def numeric?(literal) = NUMERIC_TYPES.include?(literal[:type].to_s)

    def same_literal?(left, right)
      left[:type].to_s == right[:type].to_s && left[:value] == right[:value]
    end

    def message(reason) = REASON_MESSAGES.fetch(reason.to_s, reason.to_s.tr("_", " "))

    def symbolize(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, item), result|
        result[key.to_sym] = item.is_a?(Hash) ? symbolize(item) : item
      end
    end
  end
end
