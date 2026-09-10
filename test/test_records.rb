# frozen_string_literal: true

require "test_helper"

class TestRecords < Minitest::Test
  def test_id_is_canonical_across_hash_order
    assert_equal Branchproof::Records.id(a: 1, b: [true, :x]),
                 Branchproof::Records.id(b: [true, :x], a: 1)
  end

  def test_freeze_deeply_freezes_records
    record = Branchproof::Records.build(a: { b: [1] })
    assert_predicate record, :frozen?
    assert_predicate record[:a], :frozen?
    assert_predicate record[:a][:b], :frozen?
  end

  def test_record_helpers_have_required_empty_collections
    diagnostic = Branchproof::Records.diagnostic(code: "x", severity: "warning", message: "m")
    assert_equal [], diagnostic[:details].fetch(:items)
    assert_nil diagnostic[:source_id]
  end

  def test_id_rejects_colliding_normalized_keys_and_invalid_text
    assert_raises(ArgumentError) { Branchproof::Records.id(a: 1, "a" => 2) }
    assert_raises(ArgumentError) { Branchproof::Records.id(value: "\xFF".b) }
  end
end
