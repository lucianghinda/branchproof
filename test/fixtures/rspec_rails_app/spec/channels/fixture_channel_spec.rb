# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureChannel, type: :channel do
  it "subscribes to the fixture stream" do
    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("fixture_records")
  end
end
