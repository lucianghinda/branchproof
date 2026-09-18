# frozen_string_literal: true

# Keep source-boundary and parameter-binding rules together for auditing.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ModuleLength, Metrics/PerceivedComplexity

module Branchproof
  # Defaults stay inline in their original lexical scope. The owner decision
  # makes body entry edits part of the same original AST edit tree as the
  # parameter expression edits.
  module DefaultInstrumentation
    def rewrite(unit:)
      decisions = Array(unit[:decisions])
      defaults = decisions.select do |decision|
        decision.dig(:instrumentation, :type) == "default" && supported?(decision)
      end
      return super unless defaults.any?

      prepared = decisions.map do |decision|
        next decision unless defaults.include?(decision)

        instrumentation = decision[:instrumentation].merge(flag: default_flag(decision, unit[:original_bytes]))
        decision.merge(instrumentation: instrumentation)
      end
      supported_ids = defaults.map { |decision| decision[:id] }
      prepared_defaults = prepared.select do |decision|
        decision.dig(:instrumentation, :type) == "default" && supported_ids.include?(decision[:id])
      end
      super(unit: unit.merge(decisions: owner_decisions(prepared, prepared_defaults)))
    end

    private

    # An enclosing flow renderer can split a callable range at its own
    # insertion point (for example an iteration callback inside a block). In
    # that case the owner decision cannot be rendered as one child. Preserve
    # the original offset by placing its supplied markers at the chunk that
    # begins at the body entry.
    def render_children(bytes, start, length, nested, encloses)
      output = super
      finish = start + length
      crossing = nested.select do |child|
        next false unless child.dig(:instrumentation, :type) == "default_owner"

        owner = child.dig(:instrumentation, :owner)
        owner && owner[:body_start] == start &&
          (owner[:byte_start] < start || owner[:byte_start] + owner[:byte_length] > finish)
      end
      return output if crossing.empty?

      marker = crossing.flat_map { |owner| owner_markers(owner, encloses[owner] || [], bytes) }.join
      marker.empty? ? output : "#{marker}#{output}"
    end

    def encloses_decision?(outer, inner)
      same_range = outer[:byte_start] == inner[:byte_start] && outer[:byte_length] == inner[:byte_length]
      if same_range && inner.dig(:instrumentation, :type) == "default_owner"
        return true unless outer.dig(:instrumentation, :type) == "default_owner"
      elsif same_range && outer.dig(:instrumentation, :type) == "default_owner"
        return false
      end
      super
    end

    def render_flow(bytes, decision, nested, encloses)
      if decision.dig(:instrumentation, :type) == "default_owner"
        return render_default_owner(bytes, decision, nested, encloses)
      end
      return super unless decision.dig(:instrumentation, :type) == "default"

      value = decision.dig(:instrumentation, :value_range)
      flag = decision.dig(:instrumentation, :flag) || default_flag(decision, bytes)
      replacement = flow_replacement(bytes, value, nested, encloses) do |expression|
        "(begin; #{flag} = true; #{self.class::RUNTIME}.default_binding(#{decision[:id].inspect}, 1); " \
          "#{expression}; end)"
      end
      flow_fragments(bytes, decision, nested, [replacement], encloses)
    end

    def owner_decisions(decisions, defaults)
      owners = defaults.group_by { |decision| decision.dig(:instrumentation, :owner) }
      additions = owners.filter_map do |owner, grouped|
        next unless owner

        first = grouped.min_by { |decision| decision[:byte_start] }
        next unless first

        first.merge(
          byte_start: owner[:byte_start], byte_length: owner[:byte_length],
          expression: nil,
          instrumentation: first[:instrumentation].merge(type: "default_owner")
        )
      end
      (decisions + additions).sort_by { |decision| [decision[:byte_start], decision[:byte_length]] }
    end

    def render_default_owner(bytes, decision, nested, encloses)
      owner = decision.dig(:instrumentation, :owner)
      return super unless owner

      bindings = nested.filter_map do |child|
        next unless child.dig(:instrumentation, :type) == "default"
        next unless child.dig(:instrumentation, :owner) == owner

        [child.dig(:instrumentation, :flag) || default_flag(child, bytes), child[:id]]
      end
      marker = bindings.map do |flag, id|
        "#{self.class::RUNTIME}.default_binding(#{id.inspect}, 0) unless #{flag}; "
      end.join
      return flow_fragments(bytes, decision, nested, [], encloses) if marker.empty?

      start = owner[:body_start] || owner[:closing_start]
      finish = (owner[:body_start] + owner[:body_length] if owner[:equal] && owner[:body_start] && owner[:body_length])
      replacements = if finish
                       [{ start: start, length: 0, text: "(begin; #{marker}" },
                        { start: finish, length: 0, text: "; end)" }]
                     else
                       [{ start: start, length: 0, text: marker }]
                     end
      flow_fragments(bytes, decision, nested, replacements, encloses)
    end

    def owner_markers(owner, nested, bytes)
      nested.filter_map do |child|
        next unless child.dig(:instrumentation, :type) == "default"
        next unless child.dig(:instrumentation, :owner) == owner.dig(:instrumentation, :owner)

        flag = child.dig(:instrumentation, :flag) || default_flag(child, bytes)
        "#{self.class::RUNTIME}.default_binding(#{child[:id].inspect}, 0) unless #{flag}; "
      end
    end

    def default_flag(decision, bytes)
      name = "__branchproof_default_#{decision[:id]}"
      name += "_" while bytes.include?(name)
      name
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ModuleLength, Metrics/PerceivedComplexity
