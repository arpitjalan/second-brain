# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::PluginsController do
  fab!(:admin)

  describe "#show" do
    it "exposes Steward with its existing enable setting and preserves the API toggle" do
      sign_in(admin)
      SiteSetting.second_brain_enabled = true

      get "/admin/plugins/discourse-steward.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include(
        "name" => "discourse-steward",
        "enabled_setting" => "second_brain_enabled",
        "enabled" => true,
      )
      get "/second-brain/agents.json"
      expect(response.status).to eq(200)

      SiteSetting.second_brain_enabled = false
      get "/admin/plugins/discourse-steward.json"
      expect(response.parsed_body["enabled"]).to eq(false)
      get "/second-brain/agents.json"
      expect(response.status).to eq(404)
    end
  end
end
