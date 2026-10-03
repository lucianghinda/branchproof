# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "git_changes"
require_relative "changed_decision_map"

module Branchproof
  # Describes tracked files and current decision IDs affected by the direct
  # commit-to-worktree comparison.
  class ChangedScope
    def initialize(root:, ref:)
      raise ArgumentError, "root must be an absolute path" unless root.is_a?(String) && Pathname.new(root).absolute?

      @root = File.realpath(root)
      @ref = ref
    rescue SystemCallError => e
      raise ArgumentError, "project root is unavailable: #{e.message}"
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Coordinates Git capture, inventory checks, and ordered membership.
    def call(inventory:)
      validate_inventory!(inventory)
      changes = GitChanges.new(root: @root, ref: @ref).call(include_patch_lines: true)
      source_units = Array(value(inventory, :source_units))
      decisions = Array(value(inventory, :decisions))
      sources_by_path = source_units.to_h { |unit| [value(unit, :relative_path), unit] }
      selected_ids = []
      output_files = changes[:files].map do |file|
        path = file[:path]
        source = sources_by_path[path]
        next public_file(file) unless source && file[:status] != "D"

        bytes = current_bytes!(source, path)
        original_decisions = decisions.select { |decision| decision[:source_id] == source[:source_id] }
        if file[:status] == "A" || file[:status].start_with?("R")
          ChangedDecisionMap.new.call(bytes: bytes, path: path, decisions: original_decisions, hunks: file[:hunks],
                                      old_bytes: file[:old_bytes] || "")
          selected_ids.concat(original_decisions.map { |decision| decision[:id] })
        else
          selected_ids.concat(ChangedDecisionMap.new.call(
                                bytes: bytes, path: path, decisions: original_decisions, hunks: file[:hunks],
                                old_bytes: file[:old_bytes] || ""
                              ))
        end
        current_bytes!(source, path)
        public_file(file)
      end
      after_changes = GitChanges.new(root: @root, ref: changes[:base_commit]).call(include_patch_lines: true)
      unless after_changes[:files] == changes[:files]
        raise ArgumentError,
              "tracked Git changes moved while changed scope was being captured; retry with a fresh inventory"
      end

      selected_ids = decisions.filter_map { |decision| decision[:id] if selected_ids.include?(decision[:id]) }
      Records.build(**changes.except(:files),
                    status: selected_ids.empty? ? "empty" : "complete",
                    files: output_files, decision_ids: selected_ids)
    end

    private

    def validate_inventory!(inventory)
      raise ArgumentError, "inventory must be a source inventory record" unless inventory.is_a?(Hash)
      raise ArgumentError, "inventory root does not match project root" unless File.realpath(value(inventory,
                                                                                                   :root)) == @root
    rescue SystemCallError, TypeError
      raise ArgumentError, "inventory root does not match project root"
    end

    def current_bytes!(source, path)
      bytes = value(source, :original_bytes)
      digest = value(source, :digest)
      current_path = File.expand_path(path, @root)
      unless bytes.is_a?(String) && digest.is_a?(String) && Digest::SHA256.hexdigest(bytes) == digest &&
             File.file?(current_path) && File.binread(current_path) == bytes
        raise ArgumentError, "inventory source #{path.inspect} is stale; rebuild the current source inventory"
      end

      bytes
    end

    def public_file(file)
      file.merge(hunks: Array(file[:hunks]).map do |hunk|
        hunk.slice(:old_start, :old_count, :new_start, :new_count)
      end).except(:old_bytes)
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end
  end
end
