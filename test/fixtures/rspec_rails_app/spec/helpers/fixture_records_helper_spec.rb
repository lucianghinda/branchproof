# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureRecordsHelper, type: :helper do
  it "formats a heading" do
    expect(helper.record_heading(FixtureRecord.new(name: "helper"))).to eq("Record: helper")
  end
end
