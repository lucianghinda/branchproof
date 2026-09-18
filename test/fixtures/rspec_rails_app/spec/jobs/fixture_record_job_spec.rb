# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureRecordJob, type: :job do
  it "enqueues and performs a record creation" do
    expect { described_class.perform_now("job") }.to change(FixtureRecord, :count).by(1)
  end
end
