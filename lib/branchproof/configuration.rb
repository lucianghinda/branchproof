# frozen_string_literal: true

require "json"
require_relative "coverage_policy"

module Branchproof
  # Loads and validates the project-local .branchproof.json policy.
  class Configuration
    SCHEMA_VERSION = 1
    PROJECTS = %w[auto ruby rails].freeze
    FRAMEWORKS = %w[auto minitest rspec].freeze
    MINIMUM_CRITERIA = CoveragePolicy::CRITERIA.keys.freeze
    FIELDS = %w[schema_version project framework sources tests exclude minimum].freeze

    class << self
      def load(path:, root:, explicit: false, disabled: false)
        return nil if disabled

        root = File.expand_path(root)
        path = File.expand_path(path, root)
        return nil unless ensure_file!(path, explicit)

        payload = read_payload(path)
        validate(payload, path: path, root: root)
      end

      private

      def ensure_file!(path, explicit)
        unless File.exist?(path)
          return nil unless explicit

          raise ArgumentError, "configuration file does not exist: #{path}"
        end
        return true if File.file?(path)

        raise ArgumentError, "configuration path is not a file: #{path}"
      end

      def read_payload(path)
        JSON.parse(File.binread(path))
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid JSON configuration: #{e.message}"
      rescue SystemCallError => e
        raise ArgumentError, "configuration could not be read: #{e.message}"
      end

      def validate(payload, path:, root:)
        validate_shape!(payload)
        validate_values!(payload)

        payload.each_with_object({ schema_version: SCHEMA_VERSION, path: path, root: root }) do |(key, value), result|
          next if key == "schema_version"

          result[key.to_sym] = key == "minimum" ? value.transform_keys(&:to_s) : value
        end
      end

      def validate_shape!(payload)
        raise ArgumentError, "configuration must be a JSON object" unless payload.is_a?(Hash)

        unknown = payload.keys - FIELDS
        return if unknown.empty? && valid_schema_version?(payload["schema_version"])

        raise ArgumentError, "configuration has unknown fields: #{unknown.join(", ")}" unless unknown.empty?

        raise ArgumentError, "configuration schema_version must be #{SCHEMA_VERSION}"
      end

      def valid_schema_version?(value)
        value.is_a?(Integer) && value == SCHEMA_VERSION
      end

      def validate_values!(payload)
        validate_enum(payload, "project", PROJECTS)
        validate_enum(payload, "framework", FRAMEWORKS)
        %w[sources tests].each { |field| validate_nonempty_strings(payload, field) if payload.key?(field) }
        validate_strings(payload, "exclude") if payload.key?("exclude")
        validate_minimum(payload["minimum"]) if payload.key?("minimum")
      end

      def validate_enum(payload, field, values)
        return unless payload.key?(field)

        value = payload[field]
        raise ArgumentError, "configuration #{field} must be a string" unless value.is_a?(String)
        raise ArgumentError, "configuration #{field} must be #{values.join(", ")}" unless values.include?(value)
      end

      def validate_nonempty_strings(payload, field)
        value = payload[field]
        valid = value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.empty? }
        raise ArgumentError, "configuration #{field} must be a nonempty array of strings" unless valid
      end

      def validate_strings(payload, field)
        value = payload[field]
        valid = value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
        raise ArgumentError, "configuration #{field} must be an array of strings" unless valid
      end

      def validate_minimum(value)
        raise ArgumentError, "configuration minimum must be an object" unless value.is_a?(Hash)

        CoveragePolicy.normalize(value)
      rescue ArgumentError => e
        raise ArgumentError, "configuration minimum #{e.message.sub(/\Acoverage minimum for /, "")}"
      end
    end
  end
end
