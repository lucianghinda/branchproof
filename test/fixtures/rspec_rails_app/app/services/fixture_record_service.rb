# frozen_string_literal: true

class FixtureRecordService
  def self.call(name:, enabled: true)
    return FixtureRecord.create!(name: name, enabled: true) if enabled

    FixtureRecord.create!(name: name, enabled: false)
  end
end
