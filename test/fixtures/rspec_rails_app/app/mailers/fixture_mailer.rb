# frozen_string_literal: true

class FixtureMailer < ActionMailer::Base
  default from: "fixture@example.test"

  def created(record)
    @record = record
    mail(to: "fixture@example.test", subject: "Created #{@record.name}")
  end
end
