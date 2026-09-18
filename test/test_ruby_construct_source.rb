# frozen_string_literal: true

require "json"
require "test_helper"

class TestRubyConstructSource < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/ruby_constructs", __dir__)
  EXPECTATIONS_PATH = File.join(FIXTURE_ROOT, "expectations/source.json")
  MANIFEST_PATHS = Dir[File.join(FIXTURE_ROOT, "*.json")].freeze
  LOCATION_KEYS = %i[byte_start byte_length line column].freeze

  def setup
    @manifests = MANIFEST_PATHS.flat_map { |path| JSON.parse(File.read(path)) }
    @expectations = JSON.parse(File.read(EXPECTATIONS_PATH)).fetch("entries")
    @source = Branchproof::Source.new(root: FIXTURE_ROOT, limits: Branchproof::Limits.default)
  end

  def test_expectations_cover_exactly_the_native_corpus
    ids = @manifests.map { |entry| entry.fetch("id") }
    assert_equal 142, ids.length
    assert_equal ids.sort, @expectations.keys.sort
    assert_equal ids.uniq.length, ids.length
    assert(@expectations.values.all? { |entry| entry.fetch("file").end_with?(".rb") })
  end

  def test_source_inventory_matches_reviewed_expectations
    @manifests.each do |manifest|
      id = manifest.fetch("id")
      expected = @expectations.fetch(id)
      path = expected.fetch("file")
      assert_equal canonical_filename(id), path, id
      inventory = @source.inventory(paths: [path])
      source_unit = inventory.fetch(:source_units).fetch(0)
      decisions = inventory.fetch(:decisions)

      assert_equal path, source_unit.fetch(:relative_path), id
      assert_equal expected.fetch("decisions").length, decisions.length, id
      decisions.zip(expected.fetch("decisions")).each do |decision, expectation|
        assert_equal expectation.fetch("kind"), decision.fetch(:kind), id
        assert_equal expectation.fetch("context"), decision.fetch(:context), id
        assert_equal expectation.fetch("support"), decision.fetch(:support_status), id
        assert_equal expectation.fetch("expression"), decision.fetch(:expression), id
        assert_equal(
          expectation.fetch("conditions").map { |condition| condition.fetch("expression") },
          decision.fetch(:conditions).map { |condition| condition.fetch(:expression) }, id
        )
        assert_equal expectation.fetch("reasons"), decision.fetch(:support_reasons), id
        LOCATION_KEYS.each do |key|
          assert_equal expectation.fetch(key.to_s), decision.fetch(key), id
        end
        expectation.fetch("conditions").zip(decision.fetch(:conditions)).each do |expected_condition, condition|
          LOCATION_KEYS.each do |key|
            assert_equal expected_condition.fetch(key.to_s), condition.fetch(key), id
          end
        end
      end

      assert_equal expected.fetch("diagnostics"),
                   inventory.fetch(:diagnostics).map { |diagnostic| diagnostic.fetch(:code) }, id
      assert_ranges_are_valid(source_unit, decisions, id)
      assert_support_classification_is_explicit(decisions, id)
    end
  end

  def test_boolean_inventory_has_no_duplicate_semantic_ranges
    @manifests.each do |manifest|
      id = manifest.fetch("id")
      expected = @expectations.fetch(id)
      inventory = @source.inventory(paths: [expected.fetch("file")])
      booleans = inventory.fetch(:decisions).select { |decision| decision.fetch(:kind) == "boolean" }
      ranges = booleans.map { |decision| decision.values_at(:byte_start, :byte_length) }
      assert_equal ranges.uniq, ranges, id
    end
  end

  def test_reviewed_anchors_preserve_operand_locations_and_guard_classification
    log09 = inventory_for("log_09.rb")
    repeated = log09.fetch(:decisions).fetch(0)
    assert_equal "check.call && check.call", repeated.fetch(:expression)
    assert_equal(["check.call", "check.call"],
                 repeated.fetch(:conditions).map { |condition| condition.fetch(:expression) })
    assert_operator repeated.fetch(:conditions).fetch(1).fetch(:byte_start), :>, repeated.fetch(:conditions).fetch(0).fetch(:byte_start)
    assert_equal repeated.fetch(:conditions).fetch(0).fetch(:byte_length), repeated.fetch(:conditions).fetch(1).fetch(:byte_length)

    guarded = inventory_for("pat_24.rb").fetch(:decisions)
    outer = guarded.find { |decision| decision.fetch(:context) == "case_in" }
    guard = guarded.find { |decision| decision.fetch(:context) == "pattern_guard" }
    assert_equal %w[pattern case_in UNSUPPORTED], outer.values_at(:kind, :context, :support_status)
    assert_equal ["unsupported_pattern_guard"], outer.fetch(:support_reasons)
    assert_equal %w[boolean pattern_guard SUPPORTED], guard.values_at(:kind, :context, :support_status)
    assert_equal(["years >= 18", "(trace << \"permission\"; permitted)"],
                 guard.fetch(:conditions).map { |condition| condition.fetch(:expression) })
    assert_equal(1, guarded.count { |decision| decision.fetch(:context) == "case_in" })
    assert_equal(1, guarded.count { |decision| decision.fetch(:context) == "pattern_guard" })
  end

  private

  def assert_ranges_are_valid(source_unit, decisions, id)
    bytesize = source_unit.fetch(:original_bytes).bytesize
    decisions.each do |decision|
      start_offset = decision.fetch(:byte_start)
      length = decision.fetch(:byte_length)
      assert_operator start_offset, :>=, 0, id
      assert_operator length, :>, 0, id
      assert_operator start_offset + length, :<=, bytesize, id
      decision.fetch(:conditions).each do |condition|
        condition_start = condition.fetch(:byte_start)
        condition_length = condition.fetch(:byte_length)
        assert_operator condition_start, :>=, start_offset, id
        assert_operator condition_start + condition_length, :<=, start_offset + length, id
      end
    end
  end

  def assert_support_classification_is_explicit(decisions, id)
    decisions.each do |decision|
      if decision.fetch(:support_status) == "SUPPORTED"
        assert_empty decision.fetch(:support_reasons), id
      else
        assert_equal "UNSUPPORTED", decision.fetch(:support_status), id
        refute_empty decision.fetch(:support_reasons), id
      end
    end
  end

  def canonical_filename(id)
    "#{id.downcase.tr("-", "_")}.rb"
  end

  def inventory_for(file)
    @source.inventory(paths: [file])
  end
end
