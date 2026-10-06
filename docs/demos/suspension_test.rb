# frozen_string_literal: true

require_relative "access_test"

class AccessTest
  def test_suspended_paid_member
    assert_equal :denied, allowed?(true, true)
  end
end
