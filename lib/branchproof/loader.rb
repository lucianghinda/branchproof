# frozen_string_literal: true

require "digest"

module Branchproof
  # Owns the process-local CRuby compilation hook when the VM exposes it.
  class Loader
    STATUS_KEYS = %i[status reason].freeze

    def initialize(inventory:, instrumenter:)
      @inventory = inventory
      @instrumenter = instrumenter
      @diagnostics = []
      @installed = false
      @units = index_units(inventory)
      @hook_source_location = nil
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

      @installed = true
      owner = self
      RubyVM::InstructionSequence.define_singleton_method(:load_iseq) do |path|
        owner.load_iseq(path)
      end
      RubyVM::InstructionSequence.instance_variable_set(:@branchproof_load_iseq_owner, self)
      @hook_source_location = RubyVM::InstructionSequence.method(:load_iseq).source_location
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
      rewritten = @instrumenter.rewrite(unit: unit.merge(original_bytes: bytes))
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
      return "conditions cannot be instrumented: #{reasons.join(", ")}" unless reasons.empty?

      "no supported conditions to instrument"
    end

    def hook_supported?
      defined?(RubyVM::InstructionSequence) && RubyVM::InstructionSequence.respond_to?(:compile)
    end

    def competing_owner?
      return false unless RubyVM::InstructionSequence.respond_to?(:load_iseq)

      owner = RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner)
      return false if owner.equal?(self) && hook_owned?

      true
    end

    def hook_owned?
      RubyVM::InstructionSequence.respond_to?(:load_iseq) &&
        RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner).equal?(self) &&
        RubyVM::InstructionSequence.method(:load_iseq).source_location == @hook_source_location
    end

    def preloaded_target?
      @units.keys.any? { |path| $LOADED_FEATURES.any? { |feature| canonical(feature) == path } }
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

    def status(state, reason)
      { status: state.to_s, reason: reason&.to_s }.freeze
    end

    def add_diagnostic(code, message, source_id = nil, severity: "error")
      @diagnostics << { code: code.to_s, severity: severity.to_s, message: message, source_id: source_id,
                        decision_id: nil, execution_id: nil, test_id: nil, details: {} }.freeze
    end
  end
end
