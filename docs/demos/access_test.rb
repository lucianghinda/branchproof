# frozen_string_literal: true

require "minitest/autorun"
require_relative "access"

class AccessTest < Minitest::Test
  def test_paid_member
    assert_equal :allowed, allowed?(true, false)
  end

  def test_unpaid_visitor
    assert_equal :denied, allowed?(false, false)
  end
end
