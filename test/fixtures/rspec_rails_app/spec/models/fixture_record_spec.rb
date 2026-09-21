# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureRecord, type: :model do
  it "reports labels for enabled and disabled records" do
    expect(described_class.new(name: "alpha", enabled: true).label).to eq("enabled:alpha")
    expect(described_class.new(name: "alpha", enabled: false).label).to eq("disabled:alpha")
  end

  it "rolls back records between examples" do
    expect { described_class.create!(name: "transactional") }.to change(described_class, :count).by(1)
  end
end
