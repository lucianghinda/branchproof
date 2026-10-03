# frozen_string_literal: true

require "open3"
require "pathname"

module Branchproof
  # Reads the tracked working-tree delta from a validated commit to the current
  # index and worktree. Untracked files are intentionally outside this scope.
  # rubocop:disable-next Metrics/ClassLength -- Git capture phases share one validated process context.
  class GitChanges
    def initialize(root:, ref:)
      raise ArgumentError, "root must be an absolute path" unless root.is_a?(String) && Pathname.new(root).absolute?
      raise ArgumentError, "ref must be a non-empty String" unless ref.is_a?(String) && !ref.empty?

      @root = File.realpath(root)
      @ref = ref
    rescue SystemCallError => e
      raise ArgumentError, "project root is unavailable: #{e.message}"
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength -- Capture order is security-sensitive.
    def call(include_patch_lines: false)
      git_root = git_text("rev-parse", "--show-toplevel").strip
      git_root = File.realpath(git_root)
      project_prefix = relative_prefix(git_root, @root)
      base = git_text("rev-parse", "--verify", "--end-of-options", "#{@ref}^{commit}").strip
      unless base.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
        raise ArgumentError, "Git did not resolve ref #{@ref.inspect} to a commit"
      end

      reject_unmerged_index!

      files = name_status(base).filter_map do |entry|
        project_entry(entry, git_root, project_prefix, base, include_patch_lines)
      end
      unless include_patch_lines
        files = files.map do |file|
          file.merge(hunks: file[:hunks].map { |hunk| hunk.slice(:old_start, :old_count, :new_start, :new_count) })
        end
      end
      Records.build(version: "1.0", requested_ref: @ref, base_commit: base,
                    comparison: "tracked_worktree", untracked: "excluded",
                    status: files.empty? ? "empty" : "complete", files: files)
    rescue ArgumentError
      raise
    rescue StandardError => e
      raise ArgumentError, "cannot compare Git changes: #{e.message}"
    end

    private

    def git_text(*arguments)
      output, status = Open3.capture2e("git", *arguments, chdir: @root)
      return output if status.success?

      detail = output.strip
      if arguments.first == "rev-parse" && arguments.include?("--show-toplevel")
        raise git_error("project root is not inside a Git repository", detail)
      end
      if arguments.first == "rev-parse"
        raise git_error("invalid or unresolved Git commit reference #{@ref.inspect}", detail)
      end

      raise git_error("Git command failed", detail)
    end

    def git_error(message, detail)
      ArgumentError.new(detail.empty? ? message : "#{message}: #{detail}")
    end

    def relative_prefix(git_root, project_root)
      prefix = Pathname.new(project_root).relative_path_from(Pathname.new(git_root)).to_s
      return "" if prefix == "."
      return prefix if prefix != ".." && !prefix.start_with?("../")

      raise ArgumentError, "project root must be inside its Git repository"
    end

    def reject_unmerged_index!
      output, status = Open3.capture2("git", "ls-files", "-u", "-z", chdir: @root)
      raise ArgumentError, "cannot inspect Git index for merge conflicts" unless status.success?
      return if output.empty?

      raise ArgumentError,
            "cannot compare changes while the Git index has unresolved merge entries"
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Parses Git's NUL-delimited rename protocol.
    def name_status(base)
      output = git_text("diff", "--no-ext-diff", "--no-textconv", "--no-color", "--name-status", "-z",
                        "--find-renames", base, "--")
      fields = output.split("\0", -1)
      entries = []
      index = 0
      while index < fields.length - 1
        status = fields[index]
        index += 1
        if status.start_with?("R", "C")
          old_path, new_path = fields[index, 2]
          index += 2
          entries << { status: status, old_path: safe_path(old_path), path: safe_path(new_path) }
        else
          path = fields[index]
          index += 1
          entries << { status: status, path: safe_path(path) }
        end
      end
      entries
    end

    def safe_path(path)
      path = path.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "Git reported a path that is not valid UTF-8" unless path.valid_encoding?
      raise ArgumentError, "Git reported an unsafe path" if path.empty? || path.include?("\0") || path.start_with?("/")

      segments = path.split("/")
      raise ArgumentError, "Git reported an unsafe path" if segments.include?("..") || segments.include?(".")

      path
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Handles project-boundary rename cases.
    def project_entry(entry, git_root, project_prefix, base, include_patch_lines)
      current_git_path = entry[:path]
      old_git_path = entry[:old_path]
      current_relative = within_project(current_git_path, project_prefix)
      old_relative = old_git_path && within_project(old_git_path, project_prefix)
      return if current_relative.nil? && old_relative.nil?

      # A rename crossing the project boundary is represented only when one
      # side belongs to this project; current paths remain the selection key.
      path = current_relative || old_relative
      old_path = old_relative if old_git_path && current_relative && old_relative != current_relative
      diff_path = current_git_path || old_git_path
      hunks = patch_hunks(base, diff_path, git_root)
      base_path = old_git_path || current_git_path unless entry[:status] == "A"
      old_bytes = git_blob(base, base_path, git_root) if include_patch_lines && base_path
      status = if entry[:status].start_with?("R", "C") && current_relative.nil?
                 "D"
               elsif entry[:status].start_with?("R", "C") && old_relative.nil?
                 "A"
               else
                 entry[:status]
               end
      { status: status, path: path, old_path: old_path, hunks: hunks, old_bytes: old_bytes }.compact
    end

    def within_project(path, prefix)
      return path if prefix.empty?
      return if path == prefix
      return path.delete_prefix("#{prefix}/") if path.start_with?("#{prefix}/")

      nil
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Collects patch boundaries and line context together.
    def patch_hunks(base, path, git_root)
      literal_path = ":(literal)#{path}"
      output, status = Open3.capture2("git", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=0",
                                      base, "--", literal_path, chdir: git_root)
      raise ArgumentError, "cannot read Git patch for #{path.inspect}" unless status.success?

      hunks = []
      current = nil
      output.each_line do |line|
        match = line.match(/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
        if match
          current = { old_start: match[1].to_i, old_count: (match[2] || "1").to_i,
                      new_start: match[3].to_i, new_count: (match[4] || "1").to_i,
                      old_lines: [], new_lines: [] }
          hunks << current
        elsif current && line.start_with?("-") && !line.start_with?("---")
          current[:old_lines] << line.delete_prefix("-").delete_suffix("\n")
        elsif current && line.start_with?("+") && !line.start_with?("+++")
          current[:new_lines] << line.delete_prefix("+").delete_suffix("\n")
        end
      end
      hunks
    end

    def git_blob(base, path, git_root)
      output, status = Open3.capture2("git", "cat-file", "blob", "#{base}:#{path}", chdir: git_root)
      raise ArgumentError, "cannot read base content for #{path.inspect}" unless status.success?

      output
    end
  end
end
