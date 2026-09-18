# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureRecordService do
  before { FixtureRecordService.call(name: "before") }
  after { FixtureRecordService.call(name: "after", enabled: false) }

  it "creates an enabled record by default" do
    record = described_class.call(name: "service")

    expect(record).to be_persisted
    expect(record).to be_enabled
  end

  it "preserves an explicitly disabled record" do
    expect(FixtureRecord.count).to eq(1)
    expect(described_class.call(name: "service", enabled: false)).not_to be_enabled
  end
end
