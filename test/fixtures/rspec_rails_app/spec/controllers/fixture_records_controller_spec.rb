# frozen_string_literal: true

require "rails_helper"

RSpec.describe FixtureRecordsController, type: :controller do
  describe "GET #show" do
    it "renders the selected record" do
      record = FixtureRecord.create!(name: "controller")

      get :show, params: { id: record.id }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@record).label).to eq("enabled:controller")
    end
  end
end
