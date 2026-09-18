# frozen_string_literal: true

class FixtureRecordJob < ActiveJob::Base
  def perform(name)
    FixtureRecordService.call(name: name)
  end
end
