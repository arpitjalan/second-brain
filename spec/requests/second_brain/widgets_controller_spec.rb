# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::WidgetsController do
  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://family.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "fam-token"
  end

  fab!(:owner, :user)
  fab!(:other, :user)
  fab!(:personal_bot) { Fabricate(:user, username: "stan_arpit") }

  let!(:personal_agent) do
    SecondBrain::AgentRecord.create!(
      bot_user_id: personal_bot.id,
      term_llm_url: "http://personal.test/chat",
      term_llm_token: "pers-token",
      owner_user_id: owner.id,
      forum_role: "tl4",
    )
  end

  describe "GET /second-brain/agent-widgets/:agent/*path (access)" do
    it "lets the owner load their personal agent's widget (with that agent's token)" do
      stub =
        stub_request(:get, "http://personal.test/chat/widgets/chore").with(
          headers: { "Authorization" => "Bearer pers-token" },
        ).to_return(status: 200, body: "<b>chore</b>", headers: { "Content-Type" => "text/html" })

      sign_in(owner)
      get "/second-brain/agent-widgets/stan_arpit/chore"
      expect(response.status).to eq(200)
      expect(response.body).to include("chore")
      expect(stub).to have_been_requested
    end

    it "forbids a non-owner from loading someone else's personal widget" do
      sign_in(other)
      get "/second-brain/agent-widgets/stan_arpit/chore/"
      expect(response.status).to eq(403)
    end

    it "404s an unknown agent" do
      sign_in(owner)
      get "/second-brain/agent-widgets/nobody/chore/"
      expect(response.status).to eq(404)
    end
  end

  describe "GET /second-brain/list-widgets (aggregation + access)" do
    before do
      stub_request(:get, "http://family.test/chat/admin/widgets/status").to_return(
        status: 200,
        body: { widgets: [{ mount: "famwidget", title: "Fam" }] }.to_json,
      )
      stub_request(:get, "http://personal.test/chat/admin/widgets/status").to_return(
        status: 200,
        body: { widgets: [{ mount: "mine", title: "Mine" }] }.to_json,
      )
    end

    it "gives the owner family + their own, tagged + agent-scoped urls" do
      sign_in(owner)
      get "/second-brain/list-widgets.json"
      expect(response.status).to eq(200)
      widgets = response.parsed_body["widgets"]
      fam = widgets.find { |w| w["mount"] == "famwidget" }
      mine = widgets.find { |w| w["mount"] == "mine" }
      expect(fam["owned"]).to eq(false)
      expect(fam["url"]).to eq("/second-brain/widgets/famwidget")
      expect(mine["owned"]).to eq(true)
      expect(mine["url"]).to eq("/second-brain/agent-widgets/stan_arpit/mine")
    end

    it "never lists another member's personal widgets" do
      sign_in(other)
      get "/second-brain/list-widgets.json"
      mounts = response.parsed_body["widgets"].map { |w| w["mount"] }
      expect(mounts).to include("famwidget")
      expect(mounts).not_to include("mine")
    end
  end
end
