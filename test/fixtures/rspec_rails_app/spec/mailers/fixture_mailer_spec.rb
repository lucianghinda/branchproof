# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureMailer, type: :mailer do
  it "addresses the fixture recipient" do
    mail = described_class.created(FixtureRecord.new(name: "mail")).deliver_now

    expect(mail.to).to eq(["fixture@example.test"])
    expect(mail.subject).to include("mail")
  end
end
