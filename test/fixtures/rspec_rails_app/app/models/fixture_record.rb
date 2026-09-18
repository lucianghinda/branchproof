# frozen_string_literal: true

class FixtureRecord < ActiveRecord::Base
  validates :name, presence: true

  scope :enabled, -> { where(enabled: true) }

  def label
    enabled? ? "enabled:#{name}" : "disabled:#{name}"
  end
end
