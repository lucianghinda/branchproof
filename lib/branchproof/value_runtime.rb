# frozen_string_literal: true

module Branchproof
  # Runtime mapping for value observations.
  module ValueRuntime
    DOMAINS = {
      "truthiness" => ->(value) { value ? 1 : 0 },
      "defined" => ->(value) { value ? 1 : 0 },
      "lookup" => lambda { |value|
        if nil.equal?(value)
          2
        else
          (value ? 0 : 1)
        end
      },
      "comparison" => ->(value) { comparison_index(value) },
      "dispatch" => ->(_value) { 0 }
    }.freeze

    # rubocop:disable Style/CaseEquality, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def comparison_index(value)
      return 3 if nil.equal?(value)
      return unless Integer === value || Float === value || Rational === value
      return if Float === value && value.nan?
      return 0 if value < 0 # rubocop:disable Style/NumericPredicate
      return 1 if value == 0 # rubocop:disable Style/NumericPredicate
      return 2 if value > 0 # rubocop:disable Style/NumericPredicate

      nil
    end
    module_function :comparison_index
    # rubocop:enable Style/CaseEquality, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def set_alternative_count(decision_id, count)
      frame = current_frame(decision_id)
      frame[:alternative_count] = count if frame
      nil
    end

    # rubocop:disable-next Metrics/MethodLength -- trace state branches are explicit.
    def value_path(decision_id, value, domain)
      frame = current_frame(decision_id)
      return value unless frame

      index = DOMAINS.fetch(domain.to_s).call(value)
      if index
        frame[:observations] = if frame.fetch(:alternative_count, index + 1) == 2
                                 [[0, index.zero?], [1, index == 1]]
                               else
                                 (0..index).map { |position| [position, position == index] }
                               end
        frame[:outcome] = true
        frame[:finished] = true
      end
      value
    rescue NoMethodError, ArgumentError
      # A user-defined <=> may return an incomparable object. Preserve it and
      # leave the vector incomplete instead of inventing a domain bucket.
      value
    end

    def dispatch_path(decision_id, value, raised)
      frame = current_frame(decision_id)
      return value unless frame

      index = raised ? 1 : 0
      frame[:observations] = [[0, index.zero?], [1, index == 1]]
      frame[:outcome] = true
      frame[:finished] = true
      value
    end
  end
end
