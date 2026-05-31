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

    it "rewrites absolute widget-base paths in the HTML back to the owning agent" do
      html = +'<a href="/chat/widgets/sub">x</a>' \
        '<script>fetch("/second-brain/widgets/data")</script>' \
        '<img src="relative/pic.png">'
      stub_request(:get, "http://personal.test/chat/widgets/dash").to_return(
        status: 200,
        body: html,
        headers: { "Content-Type" => "text/html" },
      )

      sign_in(owner)
      get "/second-brain/agent-widgets/stan_arpit/dash"
      expect(response.status).to eq(200)
      # absolute term-llm + family-proxy refs now point at THIS agent's prefix...
      expect(response.body).to include("/second-brain/agent-widgets/stan_arpit/sub")
      expect(response.body).to include("/second-brain/agent-widgets/stan_arpit/data")
      expect(response.body).not_to include("/chat/widgets/")
      expect(response.body).not_to include("/second-brain/widgets/")
      # ...while relative refs (the common case) are left untouched.
      expect(response.body).to include('src="relative/pic.png"')
    end

    it "injects a <base href> so a directory widget's relative fetches resolve (slash-independent)" do
      # term-llm 301s a widget directory to its trailing-slash form; the proxy follows
      # it and pins the page's base there, so a no-slash URL still resolves correctly
      # WITHOUT a browser redirect (a redirect would loop on this glob route).
      stub_request(:get, "http://personal.test/chat/widgets/board").to_return(
        status: 301,
        headers: { "Location" => "http://personal.test/chat/widgets/board/" },
      )
      stub_request(:get, "http://personal.test/chat/widgets/board/").to_return(
        status: 200,
        body: "<html><head><title>b</title></head><body>x</body></html>",
        headers: { "Content-Type" => "text/html" },
      )

      sign_in(owner)
      get "/second-brain/agent-widgets/stan_arpit/board" # no trailing slash
      expect(response.status).to eq(200) # served, not redirected → no loop
      expect(response.body).to include('<base href="/second-brain/agent-widgets/stan_arpit/board/">')
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

    it "forwards a widget's write (POST body + content-type) upstream with the agent's token" do
      # Interactive widgets (e.g. movie-night-picker's "Add") POST to their backend;
      # the proxy must carry the method, body, and content-type to term-llm — not just GET.
      stub =
        stub_request(:post, "http://personal.test/chat/widgets/movie-night-picker/api/movies")
          .with(
            headers: { "Authorization" => "Bearer pers-token", "Content-Type" => "application/json" },
            body: '{"title":"Arrival"}',
          )
          .to_return(status: 201, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

      sign_in(owner)
      post "/second-brain/agent-widgets/stan_arpit/movie-night-picker/api/movies",
           params: '{"title":"Arrival"}',
           headers: { "Content-Type" => "application/json" }
      expect(response.status).to eq(201)
      expect(response.parsed_body["ok"]).to eq(true)
      expect(stub).to have_been_requested
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
      expect(fam["url"]).to eq("/second-brain/widgets/famwidget/") # trailing slash so relative fetches resolve
      expect(mine["owned"]).to eq(true)
      expect(mine["url"]).to eq("/second-brain/agent-widgets/stan_arpit/mine/")
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
