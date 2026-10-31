# frozen_string_literal: true

require "digest"

module Branchproof
  # Owns the process-local CRuby compilation hook when the VM exposes it.
  class Loader
    # Prepended once per process, because a prepend cannot be undone. It asks
    # the current owner first and passes other files to any older hook, such
    # as the one bootsnap 1.26.1+ installs when it is required.
    module Hook
      def load_iseq(path)
        owner = RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner)
        iseq = owner&.load_iseq(path)
        return iseq if iseq

        defined?(super) ? super : nil
      end
    end

    def initialize(inventory:, instrumenter:)
      @inventory = inventory
      @instrumenter = instrumenter
      @diagnostics = []
      @installed = false
      @units = index_units(inventory)
    end

    def install
      return status(:rejected, :preloaded_target) if preloaded_target?

      unless hook_supported?
        add_diagnostic("unsupported_runtime", "RubyVM::InstructionSequence cannot install a load_iseq hook")
        return status(:rejected, :unsupported_runtime)
      end
      if competing_owner?
        add_diagnostic("loader_conflict", "another load_iseq owner is already installed")
        return status(:rejected, :loader_conflict)
      end

      RubyVM::InstructionSequence.singleton_class.prepend(Hook)
      unless hook_on_top?
        add_diagnostic("loader_conflict", "another load_iseq hook takes precedence")
        return status(:rejected, :loader_conflict)
      end

      @installed = true
      RubyVM::InstructionSequence.instance_variable_set(:@branchproof_load_iseq_owner, self)
      status(:installed, nil)
    end

    def load_iseq(path)
      return nil unless @installed

      unit = @units[path] || @units[canonical(path)]
      return nil unless unit

      bytes = File.binread(path)
      if digest_for(bytes) != expected_digest(unit)
        add_diagnostic("source_drift", "selected source changed after inventory", unit[:source_id])
        return nil
      end
      begin
        rewritten = @instrumenter.rewrite(unit: unit.merge(original_bytes: bytes))
      rescue StandardError => e
        add_diagnostic("rewrite_failure", "#{e.class}: #{e.message}", unit[:source_id], severity: "error")
        return nil
      end
      Array(rewritten[:diagnostics]).each do |diagnostic|
        add_diagnostic(diagnostic[:code], diagnostic[:message], unit[:source_id], severity: diagnostic[:severity])
      end
      unless rewritten[:changed]
        if Array(rewritten[:diagnostics]).empty?
          add_diagnostic("not_instrumented", unchanged_reason(unit), unit[:source_id],
                         severity: "info")
        end
        return nil
      end

      return rewritten[:iseq] if reusable_iseq?(unit, rewritten)

      RubyVM::InstructionSequence.compile(
        rewritten[:bytes], unit[:real_path] || canonical(path), unit[:real_path] || canonical(path), 1,
        compile_options(unit)
      )
    rescue Errno::ENOENT => e
      add_diagnostic("load_error", e.message, unit && unit[:source_id])
      nil
    end

    def diagnostics
      if @installed && !hook_owned?
        add_diagnostic("loader_conflict", "load_iseq hook ownership changed after installation")
        @installed = false
      end
      @diagnostics.dup.freeze
    end

    private

    def unchanged_reason(unit)
      decisions = Array(unit[:decisions])
      reasons = decisions.flat_map { |decision| Array(decision[:support_reasons]) }.uniq
      unless reasons.empty?
        heredocs = decisions.filter_map do |decision|
          next unless Array(decision[:support_reasons]).include?("unsupported_heredoc")

          line = decision[:line]
          column = decision[:column].is_a?(Integer) ? decision[:column] + 1 : nil
          construct = decision[:expression].to_s.lines.first.to_s.strip
          location = [unit[:relative_path] || unit[:absolute_path], line, column].compact.join(":")
          "#{location} (heredoc predicate #{construct})"
        end
        detail = heredocs.empty? ? "" : " (#{heredocs.join(", ")})"
        return "conditions cannot be instrumented: #{reasons.join(", ")}#{detail}"
      end

      "no supported conditions to instrument"
    end

    def hook_supported?
      defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.respond_to?(:compile)
    end

    # Another live loader owns the hook. Older foreign hooks are fine: Hook
    # runs before them and passes unselected files on.
    def competing_owner?
      owner = RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner)
      !owner.nil? && !owner.equal?(self)
    end

    def hook_on_top?
      RubyVM::InstructionSequence.method(:load_iseq).owner.equal?(Hook)
    end

    def hook_owned?
      RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner).equal?(self) &&
        hook_on_top?
    end

    def preloaded_target?
      loaded = $LOADED_FEATURES.each_with_object(Set.new) { |feature, set| set << canonical(feature) }
      @units.keys.any? { |path| loaded.include?(canonical(path)) }
    end

    def index_units(inventory)
      Array(inventory[:source_units]).each_with_object({}) do |unit, index|
        index[unit[:absolute_path]] = unit if unit[:absolute_path]
        index[unit[:real_path]] = unit if unit[:real_path]
      end
    end

    def canonical(path)
      File.realpath(path.to_s)
    rescue Errno::ENOENT
      File.expand_path(path.to_s)
    end

    def expected_digest(unit)
      unit[:digest] || digest_for(unit[:original_bytes].to_s)
    end

    def digest_for(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def compile_options(unit)
      unit[:compile_options] || {}
    end

    # The instrumenter already compiled the rewritten source once to validate it.
    # Reuse that instruction sequence instead of compiling again, but only when
    # it was built with the exact file/path/options this loader would use:
    # real_path present and equal to absolute_path (so the instrumenter's file
    # and path arguments match what we pass below), and no custom compile
    # options (the instrumenter compiles without any).
    def reusable_iseq?(unit, rewritten)
      rewritten[:iseq] && compile_options(unit).empty? &&
        unit[:real_path] && unit[:absolute_path] == unit[:real_path]
    end

    def status(state, reason)
      { status: state.to_s, reason: reason&.to_s }.freeze
    end

    def add_diagnostic(code, message, source_id = nil, severity: "error")
      @diagnostics << { code: code.to_s, severity: severity.to_s, message: message, source_id: source_id,
                        decision_id: nil, execution_id: nil, test_id: nil, details: {} }.freeze
    end
  end
end
