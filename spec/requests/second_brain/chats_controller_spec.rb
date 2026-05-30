# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::ChatsController do
  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "fam-token"
  end

  fab!(:owner) { Fabricate(:user) }
  fab!(:other) { Fabricate(:user) }
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

  describe "GET /second-brain/agents" do
    it "lists the family agent + the member's own personal agent" do
      sign_in(owner)
      get "/second-brain/agents.json"
      expect(response.status).to eq(200)
      usernames = response.parsed_body["agents"].map { |a| a["username"] }
      expect(usernames).to include(SecondBrain::Bot.user.username, "stan_arpit")
    end

    it "never exposes another member's personal agent" do
      sign_in(other)
      get "/second-brain/agents.json"
      usernames = response.parsed_body["agents"].map { |a| a["username"] }
      expect(usernames).to include(SecondBrain::Bot.user.username)
      expect(usernames).not_to include("stan_arpit")
    end
  end

  describe "POST /second-brain/chats" do
    it "defaults to the family agent (no agent param)" do
      sign_in(other)
      post "/second-brain/chats.json", params: { message: "hello" }
      expect(response.status).to eq(200)
      topic = Topic.find_by(id: URI(response.parsed_body["url"]).path[%r{/t/.+/(\d+)}, 1])
      expect(topic.topic_allowed_users.pluck(:user_id)).to include(SecondBrain::Bot.user.id)
    end

    it "lets the owner start a chat with their personal agent" do
      sign_in(owner)
      post "/second-brain/chats.json", params: { message: "hello", agent: "stan_arpit" }
      expect(response.status).to eq(200)
      topic = Topic.find_by(id: URI(response.parsed_body["url"]).path[%r{/t/.+/(\d+)}, 1])
      expect(topic.topic_allowed_users.pluck(:user_id)).to include(personal_bot.id)
    end

    it "forbids a non-owner from chatting with someone else's personal agent" do
      sign_in(other)
      post "/second-brain/chats.json", params: { message: "hello", agent: "stan_arpit" }
      expect(response.status).to eq(403)
    end

    it "404s on an unknown agent" do
      sign_in(owner)
      post "/second-brain/chats.json", params: { message: "hello", agent: "nope" }
      expect(response.status).to eq(400)
    end
  end
end
