# frozen_string_literal: true

require_relative "decision"
require "minitest/autorun"

class CliFixtureTest < Minitest::Test
  def test_true_true_vector
    assert_equal :yes, CliFixture.decide(true, true)
  end

  def test_true_false_vector
    assert_equal :no, CliFixture.decide(true, false)
  end

  def test_false_true_vector
    assert_equal :no, CliFixture.decide(false, true)
  end
end
