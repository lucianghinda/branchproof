# frozen_string_literal: true

require "json"

module Branchproof
  # Resolves supplied reports against a manifest without reading report files.
  class CollationManifest
    attr_reader :expected_ids, :declared_paths, :declared_identities, :inputs

    def self.path_identity(path)
      resolve_path_identity(File.expand_path(path.to_s), [])
    end

    def self.resolve_path_identity(path, visited_symlinks)
      absolute_path = File.expand_path(path)
      return resolve_symlink_identity(absolute_path, visited_symlinks) if File.symlink?(absolute_path)
      return File.realpath(absolute_path) if File.exist?(absolute_path)

      resolve_missing_identity(absolute_path, visited_symlinks)
    end

    def self.resolve_symlink_identity(path, visited_symlinks)
      raise ArgumentError, "symlink cycle while resolving path: #{path}" if visited_symlinks.include?(path)

      target = File.expand_path(File.readlink(path), File.dirname(path))
      resolve_path_identity(target, visited_symlinks + [path])
    end

    def self.resolve_missing_identity(path, visited_symlinks)
      parent = File.dirname(path)
      return path if parent == path

      File.join(resolve_path_identity(parent, visited_symlinks), File.basename(path))
    end
    private_class_method :resolve_path_identity, :resolve_symlink_identity, :resolve_missing_identity

    def initialize(path:, supplied_paths:)
      validate_arguments!(path, supplied_paths)
      @path = File.expand_path(path)
      @manifest_directory = File.dirname(@path)
      declarations = resolve_declarations(validate_document(read_document))
      validate_declaration_uniqueness!(declarations)
      assign_declarations(declarations)
      @inputs = supplied_paths.map { |supplied_path| resolve_input(supplied_path, declarations).freeze }.freeze
    end

    private

    def validate_arguments!(path, supplied_paths)
      raise ArgumentError, "manifest path must be a nonempty string" unless nonempty_string?(path)
      return if supplied_paths.is_a?(Array) && supplied_paths.all? { |item| nonempty_string?(item) }

      raise ArgumentError, "supplied paths must be an array of nonempty strings"
    end

    def read_document
      JSON.parse(File.binread(@path))
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid collation manifest JSON: #{e.message}"
    end

    def assign_declarations(declarations)
      @expected_ids = declarations.map { |declaration| declaration.fetch(:id) }.freeze
      @declared_paths = declarations.map { |declaration| declaration.fetch(:path) }.freeze
      @declared_identities = declarations.map { |declaration| declaration.fetch(:identity) }.freeze
    end

    def validate_document(document)
      raise ArgumentError, "manifest must be an object with a nonempty shards array" unless valid_root?(document)

      document.fetch("shards").map do |shard|
        validate_shard(shard)
      end
    end

    def valid_root?(document)
      document.is_a?(Hash) && document.keys == ["shards"] &&
        document["shards"].is_a?(Array) && !document["shards"].empty?
    end

    def validate_shard(shard)
      valid = shard.is_a?(Hash) && shard.keys.sort == %w[id report] &&
              nonempty_string?(shard["id"]) && nonempty_string?(shard["report"])
      raise ArgumentError, "each manifest shard must contain nonempty id and report strings" unless valid

      { id: shard.fetch("id"), report: shard.fetch("report") }
    end

    def resolve_declarations(shards)
      shards.map do |shard|
        path = File.expand_path(shard.fetch(:report), @manifest_directory)
        { id: shard.fetch(:id), path: path, identity: self.class.path_identity(path) }
      end
    end

    def validate_declaration_uniqueness!(declarations)
      ids = declarations.map { |declaration| declaration.fetch(:id) }
      raise ArgumentError, "manifest shard IDs must be unique" unless ids.uniq.length == ids.length

      declarations.combination(2) do |left, right|
        next unless paths_alias?(left.fetch(:path), left.fetch(:identity), right.fetch(:path), right.fetch(:identity))

        raise ArgumentError, "manifest shard paths must be unique across IDs"
      end
    end

    def resolve_input(supplied_path, declarations)
      path = File.expand_path(supplied_path)
      identity = self.class.path_identity(path)
      declaration = declarations.find do |candidate|
        paths_alias?(path, identity, candidate.fetch(:path), candidate.fetch(:identity))
      end
      raise ArgumentError, "supplied report is not declared by manifest: #{supplied_path}" unless declaration

      { id: declaration.fetch(:id), path: path }
    end

    def paths_alias?(left_path, left_identity, right_path, right_identity)
      left_path == right_path || left_identity == right_identity ||
        (File.exist?(left_path) && File.exist?(right_path) && File.identical?(left_path, right_path))
    rescue SystemCallError
      left_path == right_path || left_identity == right_identity
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
