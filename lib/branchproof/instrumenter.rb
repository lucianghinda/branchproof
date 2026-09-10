# frozen_string_literal: true

require_relative "flow_instrumentation"

module Branchproof
  # Applies the smallest possible source edits around inventoried expressions.
  # The edits are deliberately textual: Prism owns the ranges, while this class
  # never evaluates application code or introduces a Ruby scope.
  class Instrumenter
    include FlowInstrumentation

    RUNTIME = "::Branchproof::Runtime"

    def rewrite(unit:)
      bytes = unit.fetch(:original_bytes).dup.force_encoding(Encoding::BINARY)
      reasons = Array(unit[:support_reasons])
      return result(bytes, diagnostics: [diagnostic("unsupported_source", reasons.join(", "))]) unless supported?(unit)

      decisions = Array(unit[:decisions]).select { |decision| supported?(decision) }
      encloses, enclosed = build_enclosures(decisions)
      edits = decisions.filter_map do |decision|
        next if enclosed[decision]

        decision_edit(bytes, decision, encloses)
      end
      if decisions.any? && edits.empty?
        return result(bytes,
                      diagnostics: [diagnostic("invalid_range",
                                               "no valid decision ranges")])
      end

      rewritten = apply_edits(bytes, edits)
      begin
        iseq = RubyVM::InstructionSequence.compile(rewritten, unit[:absolute_path] || "(branchproof)",
                                                   unit[:real_path] || unit[:absolute_path] || "(branchproof)", 1)
      rescue SyntaxError => e
        return result(rewritten, diagnostics: [diagnostic("invalid_rewrite", e.message)])
      end
      result(rewritten.force_encoding(unit[:original_bytes].encoding), changed: edits.any?, iseq: iseq)
    end

    private

    def supported?(record)
      status = record[:support_status]
      status.nil? || status.to_s.casecmp("supported").zero?
    end

    # Precompute, once, which decisions each decision encloses (and whether it is
    # itself enclosed by any other), so rendering never re-scans the full decision
    # list at every recursion level. Safe because `encloses_decision?` containment
    # is transitive: if the encloses map for `decision` says it contains X, that
    # holds true within any nested subset that already contains `decision`.
    def build_enclosures(decisions)
      encloses = {}.compare_by_identity
      enclosed = {}.compare_by_identity
      decisions.each do |outer|
        contained = decisions.select { |inner| encloses_decision?(outer, inner) }
        encloses[outer] = contained
        contained.each { |inner| enclosed[inner] = true }
      end
      [encloses, enclosed]
    end

    def decision_edit(bytes, decision, encloses)
      start = decision[:byte_start]
      length = decision[:byte_length]
      return nil unless valid_range?(bytes, start, length)

      nested = encloses[decision] || []
      expression = render_decision(bytes, decision, nested, encloses)
      {
        start: start,
        finish: start + length,
        text: expression
      }
    end

    def render_range(bytes, decision, nested, encloses)
      start = decision[:byte_start]
      length = decision[:byte_length]
      conditions = Array(decision[:conditions]).sort_by { |condition| condition[:byte_start] }
      cursor = start
      chunks = []
      conditions.each do |condition|
        cstart = condition[:byte_start]
        clen = condition[:byte_length]
        next unless valid_range?(bytes, cstart, clen) && cstart >= start && cstart + clen <= start + length

        chunks << bytes.byteslice(cursor, cstart - cursor)
        original = render_children(bytes, cstart, clen, nested, encloses)
        chunks << condition_wrapper(decision[:id], condition[:index], original)
        cursor = cstart + clen
      end
      chunks << render_children(bytes, cursor, length - (cursor - start), nested, encloses)
      chunks.join
    end

    def render_children(bytes, start, length, nested, encloses)
      children = nested.select do |child|
        contains?(start, length, child[:byte_start], child[:byte_length])
      end
      children = children.reject do |child|
        children.any? { |candidate| encloses_decision?(candidate, child) }
      end
      children.sort_by! { |child| -child[:byte_start] }
      output = bytes.byteslice(start, length)
      children.each do |child|
        descendants = encloses[child] || []
        child_text = render_decision(bytes, child, descendants, encloses)
        offset = child[:byte_start] - start
        output[offset, child[:byte_length]] = child_text
      end
      output
    end

    def encloses_decision?(outer, inner)
      return false if outer.equal?(inner) || outer == inner
      return false unless contains?(outer[:byte_start], outer[:byte_length], inner[:byte_start], inner[:byte_length])
      return true unless outer[:byte_start] == inner[:byte_start] && outer[:byte_length] == inner[:byte_length]

      (outer[:kind] || "boolean") == "boolean" && inner[:kind] != "boolean" && !inner[:kind].nil?
    end

    def render_decision(bytes, decision, nested, encloses)
      if decision[:instrumentation]
        render_flow(bytes, decision, nested, encloses)
      else
        expression = render_range(bytes, decision, nested, encloses)
        frame(decision[:id], expression)
      end
    end

    def condition_wrapper(decision_id, index, expression)
      "#{RUNTIME}.condition(#{decision_id.inspect}, #{index}, (#{expression}))"
    end

    def frame(decision_id, expression)
      "(begin; #{RUNTIME}.enter(#{decision_id.inspect}); begin; " \
        "#{RUNTIME}.finish(#{decision_id.inspect}, (#{expression})); ensure; " \
        "#{RUNTIME}.leave(#{decision_id.inspect}); end; end)"
    end

    # Mutates `bytes` in place: it is already a fresh copy made at the top of
    # rewrite, so there is no need to copy it again before splicing edits in.
    def apply_edits(bytes, edits)
      edits.sort_by { |edit| -edit[:start] }.each do |edit|
        bytes[edit[:start]...edit[:finish]] = edit[:text]
      end
      bytes
    end

    def valid_range?(bytes, start, length)
      start.is_a?(Integer) && length.is_a?(Integer) && start >= 0 && length >= 0 && start + length <= bytes.bytesize
    end

    def contains?(outer_start, outer_length, inner_start, inner_length)
      valid_integer_range?(inner_start,
                           inner_length) && inner_start >= outer_start &&
        inner_start + inner_length <= outer_start + outer_length
    end

    def valid_integer_range?(start, length)
      start.is_a?(Integer) && length.is_a?(Integer) && start >= 0 && length >= 0
    end

    def result(bytes, changed: false, diagnostics: [], iseq: nil)
      { bytes: bytes, changed: changed, diagnostics: diagnostics, iseq: iseq }.freeze
    end

    def diagnostic(code, message)
      { code: code.to_s, severity: "warning", message: message, source_id: nil, decision_id: nil,
        execution_id: nil, test_id: nil, details: {} }.freeze
    end
  end
end
