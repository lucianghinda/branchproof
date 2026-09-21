# frozen_string_literal: true

class FixtureChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "fixture_records"
  end
end
