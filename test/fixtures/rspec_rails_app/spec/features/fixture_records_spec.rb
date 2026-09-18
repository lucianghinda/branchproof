# frozen_string_literal: true

require "rails_helper"
require "capybara/rspec"

RSpec.describe "fixture records", type: :feature do
  it "renders a record through the in-process rack app" do
    record = FixtureRecord.create!(name: "feature")

    visit "/fixture_records/#{record.id}"

    expect(page).to have_content("enabled:feature")
  end
end
