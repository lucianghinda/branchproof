# frozen_string_literal: true

require "digest"
require "json"

module Branchproof
  # Builds immutable records and stable identifiers for analysis artifacts.
  module Records
    module_function

    def build(value)
      deep_freeze(value)
    end

    def id(value)
      Digest::SHA256.hexdigest(canonical(value))
    end

    def canonical(value)
      JSON.generate(normalize(value))
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, JSON::GeneratorError => e
      raise ArgumentError, "record contains invalid text encoding: #{e.message}"
    end

    def diagnostic(code:, message:, severity: "warning", source_id: nil, decision_id: nil,
                   execution_id: nil, test_id: nil, details: {})
      build(code: code.to_s, severity: severity.to_s, message: message.to_s,
            source_id: source_id, decision_id: decision_id, execution_id: execution_id,
            test_id: test_id, details: { items: [], **details })
    end

    def source_id(relative_path:, digest:, encoding: "UTF-8")
      id(relative_path: relative_path, digest: digest, encoding: encoding)
    end

    def condition_id(decision_id, index)
      id(decision_id: decision_id, index: index)
    end

    def decision_id(source_id:, context:, byte_start:, byte_length:, tree:)
      id(source_id: source_id, context: context, byte_start: byte_start,
         byte_length: byte_length, tree: tree)
    end

    def deep_freeze(value)
      return value if value.frozen?

      case value
      when Hash
        value.transform_values { |item| deep_freeze(item) }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end

    def normalize(value)
      case value
      when Hash
        normalized = value.keys.map(&:to_s)
        raise ArgumentError, "record contains colliding hash keys" unless normalized.uniq.length == normalized.length

        value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, normalize(value[key])] }
      when Array then value.map { |item| normalize(item) }
      when Symbol then value.to_s
      when TrueClass, FalseClass, NilClass, Numeric, String then value
      else normalize_unknown(value)
      end
    end

    def normalize_unknown(value)
      value.to_s
    end
  end
end
