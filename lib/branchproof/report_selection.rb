# frozen_string_literal: true

require "pathname"

module Branchproof
  # Validates and applies terminal-only report display filters.
  # rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  class ReportSelection
    attr_reader :focus, :top

    def initialize(focus: nil, top: nil)
      @focus = normalize_focus(focus)
      @top = normalize_top(top)
    end

    def active?
      !@focus.nil? || !@top.nil?
    end

    def focus_active?
      !@focus.nil?
    end

    def focus_label
      return unless @focus

      @focus[:line] ? "#{@focus[:path]}:#{@focus[:line]}" : @focus[:path]
    end

    def matching_decision_ids(document)
      inventory = fetch(document, :source_inventory) || fetch(document, :inventory) || {}
      sources = source_map(inventory)
      Array(fetch(inventory, :decisions)).filter_map do |decision|
        next unless matches_decision?(decision, sources)

        fetch(decision, :id).to_s
      end
    end

    def filter_decisions(decisions, inventory: {})
      return decisions unless focus_active?

      sources = source_map(inventory)
      decisions.select { |decision| matches_decision?(decision, sources) }
    end

    def limit(items)
      return [items, 0] unless @top

      [items.first(@top), [items.length - @top, 0].max]
    end

    def sort_key(decision, inventory: {})
      source = source_for(decision, source_map(inventory))
      [normalize_source_path(fetch(source, :relative_path)).to_s,
       fetch(decision, :line).to_i, fetch(decision, :column).to_i, fetch(decision, :id).to_s]
    end

    private

    def normalize_focus(focus)
      return nil if focus.nil?
      raise ArgumentError, "focus must be PATH or PATH:LINE" unless focus.is_a?(String)

      raw = focus.strip
      raise ArgumentError, "focus path must not be empty" if raw.empty?

      path, line = if raw.match?(/:\d+\z/)
                     match = raw.match(/\A(.+):([0-9]+)\z/)
                     raise ArgumentError, "focus path must not be empty" unless match

                     [match[1], match[2].to_i]
                   else
                     raise ArgumentError, "focus line must be a positive integer" if raw.include?(":")

                     [raw, nil]
                   end
      raise ArgumentError, "focus line must be a positive integer" if line && line <= 0

      { path: normalize_path(path), line: line }.freeze
    end

    def normalize_top(top)
      return nil if top.nil?

      value = if top.is_a?(Integer)
                top
              elsif top.is_a?(String) && top.match?(/\A[1-9][0-9]*\z/)
                top.to_i
              end
      raise ArgumentError, "top must be a positive integer" unless value&.positive?

      value
    end

    def normalize_path(path)
      text = path.to_s
      raise ArgumentError, "focus path must not be empty" if text.empty? || text.include?("\0")

      pathname = Pathname.new(text)
      raise ArgumentError, "focus path must be project-relative" if pathname.absolute?

      normalized = pathname.cleanpath.to_s
      if normalized == "." || normalized == ".." || normalized.start_with?("../")
        raise ArgumentError, "focus path must stay within the project"
      end

      normalized
    rescue ArgumentError
      raise
    rescue StandardError => e
      raise ArgumentError, "invalid focus path: #{e.message}"
    end

    def matches_decision?(decision, sources)
      return false unless @focus

      source = source_for(decision, sources)
      return false unless normalize_source_path(fetch(source, :relative_path)) == @focus[:path]
      return true unless @focus[:line]

      start_line = fetch(decision, :line).to_i
      return false unless start_line.positive?

      end_line = start_line + fetch(decision, :expression).to_s.count("\n")
      @focus[:line].between?(start_line, end_line)
    end

    def source_for(decision, sources)
      sources[fetch(decision, :source_id).to_s] || decision
    end

    def source_map(inventory)
      Array(fetch(inventory, :source_units)).to_h do |source|
        [fetch(source, :source_id).to_s, source]
      end
    end

    def normalize_source_path(path)
      return nil if path.nil? || path.to_s.empty?
      return nil if Pathname.new(path.to_s).absolute?

      Pathname.new(path.to_s).cleanpath.to_s
    rescue ArgumentError
      nil
    end

    def fetch(hash, key)
      return nil unless hash.respond_to?(:key?)
      return hash[key] if hash.key?(key)
      return hash[key.to_s] if hash.key?(key.to_s)

      nil
    end
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
