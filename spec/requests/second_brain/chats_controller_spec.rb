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

  describe "removed search page" do
    it "does not serve the old search page or its endpoint" do
      sign_in(owner)
      get "/search-chats"
      expect(response.status).to eq(404)
      get "/second-brain/search.json"
      expect(response.status).to eq(404)
    end
  end

  describe "topic agent identity" do
    it "includes only the agent's display identity for family and personal chats" do
      sign_in(owner)

      [SecondBrain::Bot.user, personal_bot].each do |agent_user|
        topic = Fabricate(:private_message_topic, user: owner, recipient: agent_user)
        Fabricate(:post, topic: topic, user: owner)

        get "/t/#{topic.id}.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["second_brain_agent"]).to eq(
          "username" => agent_user.username,
          "name" => agent_user.name.presence || agent_user.username,
        )
      end
    end

    it "leaves human conversations without an agent identity" do
      sign_in(owner)
      topic = Fabricate(:private_message_topic, user: owner, recipient: other)
      Fabricate(:post, topic: topic, user: owner)

      get "/t/#{topic.id}.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["second_brain_agent"]).to be_nil
    end
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

    it "400s on an unknown agent (InvalidParameters)" do
      sign_in(owner)
      post "/second-brain/chats.json", params: { message: "hello", agent: "nope" }
      expect(response.status).to eq(400)
    end
  end

  describe "POST /second-brain/chats/:topic_id/make_public" do
    let(:bot) { SecondBrain::Bot.user }
    fab!(:public_category, :category)
    let!(:bot_chat) do
      topic = Fabricate(:private_message_topic, user: owner, recipient: bot)
      Fabricate(:post, topic: topic, user: owner, raw: "the chat contents") # convert needs a first post
      topic
    end

    before { SiteSetting.second_brain_public_category = public_category.id.to_s }

    it "lets the owner publish their bot chat (converts + marks shared)" do
      sign_in(owner)
      post "/second-brain/chats/#{bot_chat.id}/make_public.json"
      expect(response.status).to eq(200)
      bot_chat.reload
      expect(bot_chat.private_message?).to eq(false)
      expect(bot_chat.custom_fields["second_brain_shared"]).to be_truthy
    end

    it "lets staff publish someone else's bot chat" do
      sign_in(Fabricate(:admin))
      post "/second-brain/chats/#{bot_chat.id}/make_public.json"
      expect(response.status).to eq(200)
      expect(bot_chat.reload.private_message?).to eq(false)
    end

    it "forbids a non-owner participant from publishing" do
      Fabricate(:topic_allowed_user, topic: bot_chat, user: other) # invited in later
      sign_in(other)
      post "/second-brain/chats/#{bot_chat.id}/make_public.json"
      expect(response.status).to eq(403)
      expect(bot_chat.reload.private_message?).to eq(true) # unchanged
    end

    it "refuses a human-to-human PM (no bot participant), even for its owner" do
      human_pm = Fabricate(:private_message_topic, user: owner, recipient: other)
      sign_in(owner)
      post "/second-brain/chats/#{human_pm.id}/make_public.json"
      expect(response.status).to eq(403)
      expect(human_pm.reload.private_message?).to eq(true)
    end

    it "404s a topic that isn't a PM" do
      public_topic = Fabricate(:topic, user: owner)
      sign_in(owner)
      post "/second-brain/chats/#{public_topic.id}/make_public.json"
      expect(response.status).to eq(404)
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

  describe "POST /second-brain/answer (live form collapse)" do
    fab!(:topic) { Fabricate(:private_message_topic, user: owner, recipient: personal_bot) }
    fab!(:bot_post) { Fabricate(:post, topic: topic, user: personal_bot) }

    before do
      bot_post.custom_fields["second_brain_askuser"] = {
        call_id: "call_1",
        status: "pending",
        questions: [
          {
            header: "Vibe",
            question: "What vibe?",
            options: [{ label: "Outdoors" }],
            multi_select: false,
          },
        ],
      }.to_json
      bot_post.custom_fields["second_brain_askuser_state"] = {
        session_id: "sb_#{topic.id}",
        response_id: "resp_1",
        last_seq: 3,
        pre_text: "",
      }.to_json
      bot_post.save_custom_fields(true)

      stub_request(
        :post,
        "http://personal.test/chat/v1/sessions/sb_#{topic.id}/ask_user",
      ).to_return(
        status: 200,
        body: { status: "ok", summary: "Vibe: Outdoors" }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )
    end

    # Regression: the form would linger as an interactive prompt in the live view
    # after answering — the run finalized server-side ("done") but the client was
    # never told, so a post re-render re-painted the form from the stale "pending"
    # field. The answer action must push the terminal state to participants.
    it "publishes the answered state so live clients collapse the form to its summary" do
      sign_in(owner)
      messages =
        MessageBus.track_publish("/second-brain/askuser") do
          post "/second-brain/answer.json",
               params: {
                 post_id: bot_post.id,
                 call_id: "call_1",
                 answers: [{ selected: "Outdoors" }],
               },
               as: :json
        end

      expect(response.status).to eq(200)
      expect(messages.size).to eq(1)
      pushed = messages.first.data[:askuser]
      expect(pushed["status"]).to eq("answered")
      expect(pushed["summary"]).to eq("Vibe: Outdoors")
    end

    # The cancel branch takes a different path: no answers (skips build_answers),
    # submits cancelled:true, stamps skipped, and STILL enqueues a resume (per
    # term-llm semantics the run continues after a cancel).
    it "cancels the question (skipped) with no answers and still enqueues the resume" do
      sign_in(owner)
      expect_enqueued_with(
        job: :second_brain_reply,
        args: {
          post_id: bot_post.id,
          mode: "resume",
        },
      ) do
        post "/second-brain/answer.json",
             params: {
               post_id: bot_post.id,
               call_id: "call_1",
               cancelled: true,
             },
             as: :json
      end

      expect(response.status).to eq(200)
      expect(response.parsed_body["skipped"]).to eq(true)
      state = JSON.parse(bot_post.reload.custom_fields["second_brain_askuser"])
      expect(state["status"]).to eq("answered")
      expect(state["skipped"]).to eq(true)
      expect(
        a_request(:post, "http://personal.test/chat/v1/sessions/sb_#{topic.id}/ask_user").with(
          body: hash_including("cancelled" => true),
        ),
      ).to have_been_made
    end
  end
end
