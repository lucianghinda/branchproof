# frozen_string_literal: true

require "test_helper"

class TestBranchproof < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Branchproof::VERSION
  end

  def test_it_does_something_useful
    assert_equal Branchproof, MCDC
    assert_respond_to Branchproof::Records, :id
    assert_respond_to Branchproof::Limits, :default
  end
end
