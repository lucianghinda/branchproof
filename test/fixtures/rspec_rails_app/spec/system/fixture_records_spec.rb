# frozen_string_literal: true

require "rails_helper"

RSpec.describe "fixture records", type: :system do
  before { driven_by :rack_test }

  it "renders a record through the in-process system driver" do
    record = FixtureRecord.create!(name: "system")

    visit "/fixture_records/#{record.id}"

    expect(page).to have_content("enabled:system")
  end
end
