# frozen_string_literal: true

require "rails_helper"

RSpec.describe "fixture_records/show", type: :view do
  it "renders the record label" do
    assign(:record, FixtureRecord.new(name: "view", enabled: false))

    render

    expect(rendered).to include("disabled:view")
  end
end
