# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fixture records", type: :request do
  it "creates and renders a record through the request stack" do
    post "/fixture_records", params: { name: "from-request", enabled: "false" }

    expect(response).to have_http_status(:redirect)
    follow_redirect!
    expect(response.body).to include("disabled:from-request")
  end
end
