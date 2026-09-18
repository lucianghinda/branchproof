# frozen_string_literal: true

# rubocop:disable Layout/LineLength
require "digest"
require "json"
require_relative "version" unless defined?(Branchproof::VERSION)
require_relative "records" unless defined?(Branchproof::Records)
require_relative "limits" unless defined?(Branchproof::Limits)
module Branchproof
  # Validates, groups, and merges adapter-neutral execution evidence.
  # Stores validated observations and merges compatible worker snapshots.
  class Evidence
    SCHEMA_VERSION = "1.0"
    CRITERION_VERSION = "masking_occurrence_v1"
    TOOL_VERSION = Branchproof::VERSION
    attr_reader :inventory, :run_id

    def initialize(inventory:, limits:, run_id:)
      raise ArgumentError, "inventory is required" if inventory.nil?
      raise ArgumentError, "run_id is required" if run_id.nil? || run_id.to_s.empty?

      @inventory = inventory
      @decisions_by_id = Array(fetch_value(@inventory, :decisions)).each_with_object({}) do |raw, index|
        decision = symbolize(raw)
        index[decision[:id].to_s] = decision
      end
      @limits = normalize_limits(limits)
      @run_id = run_id.to_s
      @run_ids = [@run_id]
      @vectors = {}
      @vector_counts_by_decision = Hash.new(0)
      @owner_associations_count = 0
      @tests = {}
      @run_payloads = {}
      @abort_counts = Hash.new(0)
      @diagnostics = []
      @repetition_cache = {}
      @limited = false
      @attribution_complete = true
    end

    def register_test(test:)
      value = symbolize(test)
      id = (value[:id] || test_id(value)).to_s
      if !@tests.key?(id) && @tests.length >= @limits[:tests_per_run]
        @attribution_complete = false
        @limited = true
        return status("limited", "tests_per_run reached")
      end
      current = @tests[id] || { id: id, adapter: "unknown", name: id, source: nil, class_name: nil,
                                method_name: nil, status: "unknown", phase_counts: {} }
      merged = current.merge(value).merge(id: id)
      merged[:phase_counts] = (current[:phase_counts] || {}).merge(value[:phase_counts] || {})
      @tests[id] = deep_dup(merged)
      status("registered", nil)
    end

    def record(execution:)
      if (cached = cached_execution(execution))
        return record_cached(cached)
      end

      value = symbolize(execution)
      reason = validate_execution(value)
      return reject_record(reason) if reason

      if value[:status].to_s == "invalid"
        diagnose(diagnostic: { code: "invalid_execution", severity: "error", message: "invalid execution trace",
                               decision_id: value[:decision_id] })
        return reject_record("invalid execution")
      end
      if value[:status].to_s == "completed" && ![true, false].include?(value[:outcome])
        return reject_record("completed outcome must be boolean")
      end

      if value[:status].to_s != "completed"
        @abort_counts[value[:decision_id].to_s] += 1
        return status("recorded", nil)
      end
      decision_id = value[:decision_id].to_s
      vector_values = condition_values(decision_id, value[:observations])
      outcome = value[:outcome] ? true : false
      vector_id = Branchproof::Records.id([decision_id, vector_values, outcome])
      if new_vector?(vector_id) && vector_count(decision_id) >= @limits[:vectors_per_decision]
        @limited = true
        return status("limited", "vectors_per_decision reached")
      end
      vector = vector_for(decision_id, vector_values, outcome, vector_id)
      new_owner = if value[:test_id]
                    !vector[:test_ids].include?(value[:test_id].to_s)
                  else
                    vector[:unattributed_count].zero?
                  end
      if new_owner && owner_associations >= @limits[:owner_associations_per_run]
        @attribution_complete = false
        @limited = true
        return status("limited", "owner_associations_per_run reached")
      end
      vector[:test_ids] << value[:test_id].to_s if value[:test_id] && !vector[:test_ids].include?(value[:test_id].to_s)
      phase_map = (vector[:phases_by_test][value[:test_id].to_s] ||= []) if value[:test_id]
      phase_map << value[:phase].to_s if phase_map && !phase_map.include?(value[:phase].to_s)
      vector[:unattributed_count] += 1 unless value[:test_id]
      vector[:count] += 1
      @owner_associations_count += 1 if new_owner
      if value[:test_id] && @tests.key?(value[:test_id].to_s)
        test = @tests[value[:test_id].to_s]
        phase = value[:phase].to_s
        test[:phase_counts][phase] = test[:phase_counts].fetch(phase, 0) + 1
      end
      cache_key = execution_cache_key(value)
      @repetition_cache[cache_key[1]] = { key: cache_key, vector_id: vector_id }
      status("recorded", nil)
    rescue StandardError => e
      diagnose(diagnostic: { code: "record_failure", severity: "error", message: e.message })
      status("rejected", e.message)
    end

    def diagnose(diagnostic:)
      @diagnostics << deep_freeze(symbolize(diagnostic))
      nil
    end

    def test_phase_counts
      @tests.transform_values { |test| test[:phase_counts].dup.freeze }.freeze
    end

    def snapshot
      deep_freeze(deep_dup({ schema_version: SCHEMA_VERSION, tool_version: TOOL_VERSION,
                             criterion_version: CRITERION_VERSION,
                             runtime: RUBY_DESCRIPTION, run_ids: @run_ids.dup, inventory_digest: inventory_digest,
                             source_digests: source_digests, condition_shapes: condition_shapes,
                             tests: @tests.values, vectors: @vectors.values,
                             abort_counts: @abort_counts.dup, diagnostics: @diagnostics.map(&:dup),
                             completeness: { observation: !@limited, attribution: @attribution_complete,
                                             analysis: true } }))
    end

    def merge(snapshot:)
      backup = nil
      incoming = symbolize(snapshot)
      shape_error = validate_snapshot_shape(incoming)
      return status("rejected", shape_error) if shape_error

      reason = merge_error(incoming)
      return status("rejected", reason) if reason

      incoming_runs = Array(incoming[:run_ids]).map(&:to_s)
      return status("rejected", "run_ids must be non-empty") if incoming_runs.empty? || incoming_runs.any?(&:empty?)

      reason = validate_snapshot_vectors(incoming)
      return status("rejected", reason) if reason

      payload = canonical(incoming)
      existing = incoming_runs.select { |id| @run_payloads.key?(id) }
      if existing.any? && existing.any? { |id| @run_payloads[id] != Branchproof::Records.id(payload) }
        return status("rejected", "ambiguous overlapping run IDs")
      end
      return status("merged", nil) if existing.length == incoming_runs.length
      return status("rejected", "ambiguous overlapping run IDs") if existing.any?

      if incoming_owner_associations(incoming) > @limits[:owner_associations_per_run]
        @limited = true
        @attribution_complete = false
        return status("limited", "owner_associations_per_run reached")
      end
      backup = capture_state
      incoming_runs.each do |id|
        next if @run_payloads.key?(id)

        # All validation is complete before this first mutation, so a malformed
        # vector cannot leave a half-merged worker snapshot behind.
        @run_payloads[id] = Branchproof::Records.id(payload)
      end
      @run_ids |= incoming_runs
      incoming.fetch(:tests, []).each { register_test(test: _1) }
      incoming.fetch(:vectors, []).each { merge_vector(_1) }
      @diagnostics.concat(incoming.fetch(:diagnostics, []))
      @abort_counts.merge!(incoming.fetch(:abort_counts, {})) { |_k, a, b| a.to_i + b.to_i }
      @limited ||= !incoming.dig(:completeness, :observation)
      @attribution_complete &&= incoming.dig(:completeness, :attribution) ? true : false
      @repetition_cache.clear
      status("merged", nil)
    rescue StandardError => e
      restore_state(backup) if backup
      status("rejected", e.message)
    end

    private

    def validate_snapshot_shape(incoming)
      return "snapshot must be a hash" unless incoming.is_a?(Hash)

      required = %i[schema_version tool_version criterion_version runtime run_ids inventory_digest source_digests
                    condition_shapes tests vectors abort_counts diagnostics completeness]
      missing = required.reject { |key| incoming.key?(key) }
      return "missing snapshot field: #{missing.first}" unless missing.empty?

      valid_run_ids = incoming[:run_ids].is_a?(Array) && incoming[:run_ids].all?(String)
      return "invalid run_ids" unless valid_run_ids
      return "invalid source_digests" unless incoming[:source_digests].is_a?(Hash)
      return "invalid condition_shapes" unless incoming[:condition_shapes].is_a?(Hash)
      return "invalid diagnostics" unless incoming[:diagnostics].is_a?(Array)

      completeness = incoming[:completeness]
      valid_completeness = completeness.is_a?(Hash)
      valid_completeness &&= %i[observation attribution analysis].all? do |key|
        [true, false].include?(completeness[key])
      end
      return "invalid completeness" unless valid_completeness

      nil
    end

    def validate_execution(value)
      return "execution must be a hash" unless value.is_a?(Hash)

      %i[run_id decision_id test_id phase observations outcome status].each do |key|
        return "missing #{key}" unless value.key?(key)
      end
      return "run mismatch" unless value[:run_id].to_s == @run_id
      return "invalid status" unless %w[completed aborted invalid].include?(value[:status].to_s)
      return "invalid phase" unless %w[setup body teardown suite unattributed].include?(value[:phase].to_s)
      return "invalid observations" unless value[:observations].is_a?(Array) && value[:observations].all? do |pair|
        pair.is_a?(Array) && pair.length == 2 && pair[0].is_a?(Integer) && [true, false].include?(pair[1])
      end

      decision = @decisions_by_id[value[:decision_id].to_s]
      return "unknown decision" unless decision

      dimensions = alternative_decision?(decision) ? Array(decision[:alternatives]) : Array(decision[:conditions])
      return "condition count exceeds limit" if !alternative_decision?(decision) && dimensions.length > @limits[:conditions_per_decision]
      return "invalid condition index" unless value[:observations].map(&:first).uniq == value[:observations].map(&:first) && value[:observations].all? do |index, _|
        dimensions.any? do |dimension|
          dimension[:index].to_i == index
        end
      end
      return "invalid trace" unless value[:status].to_s != "completed" || valid_trace?(decision, value[:observations],
                                                                                       value[:outcome])

      nil
    end

    def valid_trace?(decision, observations, outcome)
      return valid_alternative_trace?(decision, observations, outcome) if alternative_decision?(decision)

      tree = decision[:tree]
      unless tree
        return observations.map(&:first) == observations.map(&:first).sort &&
               (outcome ? true : false) == evaluate_fallback(observations)
      end

      cursor = 0
      result = replay_tree(tree, observations, cursor)
      return false unless result

      value, consumed = result
      consumed == observations.length && value == (outcome ? true : false)
    end

    def replay_tree(node, observations, cursor)
      type = node[:type].to_s
      if type == "atom"
        pair = observations[cursor]
        return nil unless pair && pair[0].to_i == node[:index].to_i

        return [pair[1], cursor + 1]
      end
      if type == "not"
        child = replay_tree(node.fetch(:child), observations, cursor)
        return nil unless child

        child_value, next_cursor = child
        return [!child_value, next_cursor]
      end
      left = replay_tree(node.fetch(:left), observations, cursor)
      return nil unless left

      left_value, next_cursor = left
      return [left_value, next_cursor] if (type == "and" && !left_value) || (type == "or" && left_value)

      right = replay_tree(node.fetch(:right), observations, next_cursor)
      return nil unless right

      right_value, right_cursor = right
      [type == "and" ? (left_value && right_value) : (left_value || right_value), right_cursor]
    rescue KeyError
      nil
    end

    def evaluate_fallback(observations)
      observations.last&.last
    end

    def condition_values(decision_id, observations)
      count = decision_dimension_count(decision_id)
      values = Array.new(count)
      observations.each { |index, value| values[index] = value }
      values
    end

    def vector_for(decision_id, values, outcome, id)
      existing = @vectors[id]
      return existing if existing

      vector = { id: id, decision_id: decision_id, values: values.dup, outcome: outcome,
                 test_ids: [], phases_by_test: {}, unattributed_count: 0, count: 0 }
      @vectors[id] = vector
      @vector_counts_by_decision[decision_id] += 1
      vector
    end

    def merge_vector(raw)
      vector = symbolize(raw)
      id = vector[:id].to_s
      existing = @vectors[id]
      if existing
        new_test_ids = Array(vector[:test_ids]).map(&:to_s) - existing[:test_ids]
        existing[:test_ids] |= new_test_ids
        vector.fetch(:phases_by_test, {}).each do |test, phases|
          existing[:phases_by_test][test.to_s] = (existing[:phases_by_test][test.to_s] || []) | phases
        end
        was_unattributed = existing[:unattributed_count].positive?
        existing[:count] += vector[:count].to_i
        existing[:unattributed_count] += vector[:unattributed_count].to_i
        @owner_associations_count += new_test_ids.length
        @owner_associations_count += 1 if !was_unattributed && existing[:unattributed_count].positive?
      else
        decision_id = vector[:decision_id].to_s
        test_ids = Array(vector[:test_ids]).map(&:to_s)
        unattributed_count = vector[:unattributed_count].to_i
        @vectors[id] = { id: id, decision_id: decision_id,
                         values: Array(vector[:values]).dup, outcome: !!vector[:outcome], test_ids: test_ids,
                         phases_by_test: vector.fetch(:phases_by_test, {}).transform_keys(&:to_s), unattributed_count: unattributed_count, count: vector[:count].to_i }
        @vector_counts_by_decision[decision_id] += 1
        @owner_associations_count += test_ids.length
        @owner_associations_count += 1 if unattributed_count.positive?
      end
    end

    def merge_error(incoming)
      return "unsupported schema" unless incoming[:schema_version].to_s == SCHEMA_VERSION
      return "criterion mismatch" unless incoming[:criterion_version].to_s == CRITERION_VERSION
      return "inventory mismatch" unless incoming[:inventory_digest].to_s == inventory_digest
      return "source mismatch" unless normalize_mapping(incoming[:source_digests]) == normalize_mapping(source_digests)
      return "condition shape mismatch" unless canonical(incoming[:condition_shapes]) == canonical(condition_shapes)

      nil
    end

    def condition_shapes
      @decisions_by_id.transform_values do |decision|
        shape = { conditions: Array(decision[:conditions]).map { |condition| symbolize(condition) },
                  tree: symbolize(decision[:tree]) }
        if alternative_decision?(decision)
          shape[:kind] = decision[:kind].to_s
          shape[:alternatives] = Array(decision[:alternatives]).map { |alternative| symbolize(alternative) }
        end
        shape
      end
    end

    def validate_snapshot_vectors(incoming)
      vectors = incoming.fetch(:vectors, [])
      return "vectors must be an array" unless vectors.is_a?(Array)

      tests = incoming.fetch(:tests, [])
      return "tests must be an array" unless tests.is_a?(Array)
      return "tests_per_run reached" if (@tests.keys | tests.filter_map do |item|
        symbolize(item)[:id]
      end).length > @limits[:tests_per_run]
      return "invalid test record" unless tests.all? do |raw|
        test = symbolize(raw)
        test[:id] && test[:adapter] && test[:name] && test[:phase_counts].is_a?(Hash) &&
        test[:phase_counts].all? do |phase, count|
          %w[setup body teardown suite unattributed].include?(phase.to_s) && count.is_a?(Integer) && count >= 0
        end
      end

      counts = Hash.new(0)
      seen_ids = {}
      vectors.each do |raw|
        vector = symbolize(raw)
        return "invalid vector" unless vector[:id] && vector[:decision_id] && vector[:values].is_a?(Array)

        decision = @decisions_by_id[vector[:decision_id].to_s]
        return "unknown decision" unless decision

        expected_values = decision_dimension_count(decision)
        return "invalid vector shape" unless vector[:values].length == expected_values &&
                                             vector[:values].all? { |item| item.nil? || item == true || item == false }

        expected = Branchproof::Records.id([vector[:decision_id].to_s, vector[:values], vector[:outcome] ? true : false])
        return "invalid vector id" unless vector[:id].to_s == expected
        return "invalid vector outcome" unless [true, false].include?(vector[:outcome])
        return "invalid vector count" unless vector[:count].is_a?(Integer) && vector[:count].positive?
        unless vector[:unattributed_count].is_a?(Integer) && vector[:unattributed_count] >= 0 && vector[:unattributed_count] <= vector[:count]
          return "invalid unattributed count"
        end
        unless vector[:test_ids].is_a?(Array) && vector[:test_ids].uniq.length == vector[:test_ids].length && vector[:phases_by_test].is_a?(Hash)
          return "invalid vector provenance"
        end
        return "invalid vector provenance" unless vector[:phases_by_test].all? do |test, phases|
          test && phases.is_a?(Array) && phases.all? do |phase|
            %w[setup body teardown suite unattributed].include?(phase.to_s)
          end
        end
        return "invalid vector trace" unless valid_trace?(decision, vector[:values].each_with_index.filter_map do |item, index|
          [index, item] if [true, false].include?(item)
        end, vector[:outcome])
        return "duplicate vector id" if seen_ids.key?(vector[:id].to_s)

        seen_ids[vector[:id].to_s] = true
        counts[vector[:decision_id].to_s] += 1 unless @vectors.key?(vector[:id].to_s)
      end
      return "vectors_per_decision reached" if counts.any? do |id, count|
        vector_count(id) + count > @limits[:vectors_per_decision]
      end

      abort_counts = incoming.fetch(:abort_counts, {})
      return "invalid abort counts" unless abort_counts.is_a?(Hash) && abort_counts.all? do |_id, count|
        count.is_a?(Integer) && count >= 0
      end

      nil
    end

    def alternative_decision?(decision)
      kind = decision[:kind].to_s
      !kind.empty? && kind != "boolean"
    end

    def decision_dimension_count(decision_or_id)
      decision = decision_or_id.is_a?(Hash) ? decision_or_id : @decisions_by_id[decision_or_id.to_s]
      return 0 unless decision

      alternative_decision?(decision) ? Array(decision[:alternatives]).length : Array(decision[:conditions]).length
    end

    def valid_alternative_trace?(decision, observations, outcome)
      return false unless outcome == true

      alternatives = Array(decision[:alternatives])
      expected = alternatives.length
      return false unless expected.positive?
      if decision[:kind].to_s == "implicit"
        return expected == 2 && observations.length == 2 &&
               observations.map(&:first) == [0, 1] && observations.map(&:last).count(true) == 1
      end

      return false unless observations.length.between?(1, expected)

      observations.each_with_index.all? do |(index, value), position|
        index == position && value == (position == observations.length - 1)
      end
    end

    def decision_conditions(id) = (@decisions_by_id[id.to_s] || {}).fetch(:conditions, [])
    def vector_count(id) = @vector_counts_by_decision[id.to_s]
    def new_vector?(id) = !@vectors.key?(id)

    def owner_associations = @owner_associations_count

    def incoming_owner_associations(incoming)
      owners = @vectors.each_with_object({}) do |(_id, vector), result|
        vector[:test_ids].each { |test_id| result[[vector[:id], test_id]] = true }
        result[[vector[:id], :unattributed]] = true if vector[:unattributed_count].positive?
      end
      incoming.fetch(:vectors, []).each do |raw|
        vector = symbolize(raw)
        vector.fetch(:test_ids, []).each { |test_id| owners[[vector[:id], test_id.to_s]] = true }
        owners[[vector[:id], :unattributed]] = true if vector.fetch(:unattributed_count, 0).to_i.positive?
      end
      owners.length
    end

    def inventory_digest = Branchproof::Records.id({ sources: source_digests, condition_shapes: condition_shapes })

    def source_digests
      explicit = fetch_value(@inventory, :source_digests)
      return normalize_mapping(explicit) unless explicit.nil? || explicit.empty?

      units = Array(fetch_value(@inventory, :source_units))
      units.each_with_object({}) do |unit, result|
        item = symbolize(unit)
        key = item[:relative_path] || item[:source_id] || item[:absolute_path]
        result[key.to_s] = item[:digest].to_s if key && item[:digest]
      end
    end

    def fetch_value(object, key) = object.respond_to?(key) ? object.public_send(key) : object[key] || object[key.to_s]
    def status(name, reason) = { status: name.to_s, reason: reason, diagnostics: @diagnostics.map(&:dup) }

    def reject_record(reason)
      @limited = true
      diagnose(diagnostic: { code: "invalid_execution", severity: "error", message: reason.to_s })
      status("rejected", reason.to_s)
    end

    def test_id(value) = Branchproof::Records.id(value)

    def normalize_limits(value)
      return Branchproof::Limits.default if value.nil? || value == {}
      return Branchproof::Limits.normalize(value.to_h) if value.respond_to?(:to_h)

      raise ArgumentError, "limits must be a Hash"
    end

    def symbolize(value)
      return value.map { symbolize(_1) } if value.is_a?(Array)
      return value.transform_keys(&:to_sym).transform_values { symbolize(_1) } if value.is_a?(Hash)

      value
    end

    def canonical(value) = Branchproof::Records.canonical(value)

    def normalize_mapping(value)
      (value || {}).each_with_object({}) { |(key, item), result| result[key.to_s] = item.to_s }
    end

    def deep_dup(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), copy| copy[deep_dup(key)] = deep_dup(item) }
      when Array then value.map { deep_dup(_1) }
      else value
      end
    end

    def capture_state
      { vectors: deep_dup(@vectors), tests: deep_dup(@tests), run_ids: @run_ids.dup,
        run_payloads: @run_payloads.dup, diagnostics: deep_dup(@diagnostics),
        abort_counts: @abort_counts.dup, limited: @limited, attribution_complete: @attribution_complete,
        vector_counts_by_decision: @vector_counts_by_decision.dup, owner_associations_count: @owner_associations_count,
        repetition_cache: deep_dup(@repetition_cache) }
    end

    def restore_state(state)
      @vectors = state[:vectors]
      @tests = state[:tests]
      @run_ids = state[:run_ids]
      @run_payloads = state[:run_payloads]
      @diagnostics = state[:diagnostics]
      @abort_counts = state[:abort_counts]
      @vector_counts_by_decision = state[:vector_counts_by_decision]
      @owner_associations_count = state[:owner_associations_count]
      @repetition_cache = state[:repetition_cache]
      @limited = state[:limited]
      @attribution_complete = state[:attribution_complete]
    end

    def cached_execution(execution)
      return nil unless execution.is_a?(Hash)

      key = raw_execution_cache_key(execution)
      return nil unless key

      entry = @repetition_cache[key[1]]
      return nil unless entry && entry[:key] == key

      vector = @vectors[entry[:vector_id]]
      return nil unless vector

      [key, vector, raw_execution_attribution(execution)]
    end

    def record_cached(cached)
      _key, vector, value = cached
      vector[:count] += 1
      if value[:test_id] && @tests.key?(value[:test_id].to_s)
        test = @tests[value[:test_id].to_s]
        phase = value[:phase].to_s
        test[:phase_counts][phase] = test[:phase_counts].fetch(phase, 0) + 1
      end
      vector[:unattributed_count] += 1 unless value[:test_id]
      status("recorded", nil)
    end

    def raw_execution_cache_key(execution)
      required = %i[run_id decision_id test_id phase observations outcome status]
      return nil unless required.all? { |key| execution.key?(key) || execution.key?(key.to_s) }

      status = raw_value(execution, :status)
      outcome = raw_value(execution, :outcome)
      return nil unless status.to_s == "completed" && [true, false].include?(outcome)

      observations = raw_value(execution, :observations)
      return nil unless observations.is_a?(Array)

      test_id = raw_value(execution, :test_id)
      [raw_value(execution, :run_id).to_s, raw_value(execution, :decision_id).to_s,
       test_id_marker(test_id), test_id&.to_s, raw_value(execution, :phase).to_s,
       observations, outcome, status.to_s]
    end

    def execution_cache_key(value)
      key = [copy_string(value[:run_id]), copy_string(value[:decision_id]), test_id_marker(value[:test_id]),
             copy_string(value[:test_id]),
             copy_string(value[:phase]), deep_dup(value[:observations]), value[:outcome], copy_string(value[:status])]
      deep_freeze(key)
    end

    def raw_execution_attribution(execution)
      { test_id: raw_value(execution, :test_id), phase: raw_value(execution, :phase) }
    end

    def copy_string(value)
      value.nil? ? nil : value.to_s.dup
    end

    def test_id_marker(value)
      return :nil if value.nil?
      return :false_test_id if value == false

      :present
    end

    def raw_value(hash, key)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end

    def deep_freeze(value)
      case value
      when Hash then value.each do |key, item|
        deep_freeze(key)
        deep_freeze(item)
      end
      when Array then value.each { deep_freeze(_1) }
      end
      value.freeze
    end
  end
end
# rubocop:enable Layout/LineLength
