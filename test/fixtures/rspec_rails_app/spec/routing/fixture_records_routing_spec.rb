# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fixture record routes", type: :routing do
  it "routes records to the fixture controller" do
    expect(get: "/fixture_records/1").to route_to(controller: "fixture_records", action: "show", id: "1")
  end
end
