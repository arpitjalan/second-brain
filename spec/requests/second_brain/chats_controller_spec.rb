# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::ChatsController do
  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
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

  describe "POST /second-brain/answer (personal-agent privacy)" do
    fab!(:topic) { Fabricate(:private_message_topic, user: owner, recipient: personal_bot) }
    fab!(:bot_post) { Fabricate(:post, topic: topic, user: personal_bot) }

    it "forbids a non-owner participant from driving a personal agent's run" do
      Fabricate(:topic_allowed_user, topic: topic, user: other) # invited in later
      sign_in(other)
      post "/second-brain/answer.json", params: { post_id: bot_post.id, call_id: "x" }
      expect(response.status).to eq(403)
    end

    it "lets the owner past the access guard (404 with no pending prompt)" do
      sign_in(owner)
      post "/second-brain/answer.json", params: { post_id: bot_post.id, call_id: "x" }
      expect(response.status).to eq(404) # past the guard; no pending ask_user state
    end
  end

  describe "GET /second-brain/search" do
    let(:bot) { SecondBrain::Bot.user }

    before { SearchIndexer.enable }

    # Build a post carrying the unique term and make it searchable.
    def indexed_post(topic, user, raw)
      post = Fabricate(:post, topic: topic, user: user, raw: raw)
      SearchIndexer.index(post.reload, force: true)
      post
    end

    def search_as(user, q)
      sign_in(user)
      get "/second-brain/search.json", params: { q: q }
      expect(response.status).to eq(200)
      response.parsed_body["results"]
    end

    it "finds the caller's own bot chat by content" do
      topic = Fabricate(:private_message_topic, user: owner, recipient: bot)
      indexed_post(topic, owner, "A question about the boilerwarranty please")

      results = search_as(owner, "boilerwarranty")
      expect(results.map { |r| r["url"] }.join).to include(topic.relative_url)
    end

    it "never returns another member's bot chat (sb_me anchor)" do
      other_topic = Fabricate(:private_message_topic, user: other, recipient: bot)
      indexed_post(other_topic, other, "secret boilerwarranty stuff")

      expect(search_as(owner, "boilerwarranty")).to be_empty
    end

    it "excludes a personal-agent chat from a non-owner" do
      topic = Fabricate(:private_message_topic, user: owner, recipient: personal_bot)
      indexed_post(topic, owner, "private boilerwarranty for the owner")

      expect(search_as(other, "boilerwarranty")).to be_empty
    end

    it "excludes a personal-agent chat even from a non-owner invited into it" do
      topic = Fabricate(:private_message_topic, user: owner, recipient: personal_bot)
      indexed_post(topic, owner, "private boilerwarranty for the owner")
      Fabricate(:topic_allowed_user, topic: topic, user: other) # invited in later

      expect(search_as(other, "boilerwarranty")).to be_empty
    end

    it "lets the owner find their own personal-agent chat" do
      topic = Fabricate(:private_message_topic, user: owner, recipient: personal_bot)
      indexed_post(topic, owner, "my own boilerwarranty notes")

      expect(search_as(owner, "boilerwarranty").map { |r| r["url"] }.join).to include(
        topic.relative_url,
      )
    end

    it "excludes human-to-human PMs (no bot participant)" do
      human_pm = Fabricate(:private_message_topic, user: owner, recipient: other)
      indexed_post(human_pm, owner, "boilerwarranty between two humans")

      expect(search_as(owner, "boilerwarranty")).to be_empty
    end

    it "includes shared public chats that match, for any member" do
      shared = Fabricate(:topic, user: owner)
      shared.custom_fields["second_brain_shared"] = true
      shared.save_custom_fields(true)
      indexed_post(shared, owner, "a public boilerwarranty note")

      expect(search_as(other, "boilerwarranty").map { |r| r["url"] }.join).to include(
        shared.relative_url,
      )
    end

    it "dedupes to one card per topic when several posts match" do
      topic = Fabricate(:private_message_topic, user: owner, recipient: bot)
      indexed_post(topic, owner, "first boilerwarranty mention")
      indexed_post(topic, bot, "second boilerwarranty mention")

      expect(search_as(owner, "boilerwarranty").size).to eq(1)
    end

    it "returns nothing for a query under 2 chars" do
      expect(search_as(owner, "b")).to eq([])
    end

    it "handles a query with special characters without erroring" do
      expect(search_as(owner, "foo & bar :*!")).to eq([])
    end
  end
end
