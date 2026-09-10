# frozen_string_literal: true

require "test_helper"

class FixtureRailsTest < ActiveSupport::TestCase
  setup do
    @setup_marker = true
    FixtureDecisionService.new.choose(2)
  end

  teardown do
    @teardown_marker = true
    FixtureDecisionService.new.choose(0)
  end

  test "loads the service through Zeitwerk and records a decision" do
    assert @setup_marker
    assert_equal :large, FixtureDecisionService.new.choose(2)
    assert_equal :small, FixtureDecisionService.new.choose(0)
  end

  test "loads the controller through Zeitwerk" do
    assert_equal FixtureController, "FixtureController".constantize
  end
end

class FixtureControllerTest < ActionDispatch::IntegrationTest
  test "serves a real controller request" do
    get "/fixture?value=2"
    assert_response :success
    assert_equal "large", response.body
  end
end
