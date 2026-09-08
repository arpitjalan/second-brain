# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::ChatsController do
  fab!(:owner, :user)
  fab!(:other, :user)
  let(:bot) { SecondBrain::Bot.user }
  let(:topic) { Fabricate(:private_message_topic, user: owner, recipient: bot) }
  let(:path) { "/second-brain/chats/#{topic.id}/runtime.json" }

  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://agent.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "private-token"
    stub_request(:get, "http://agent.test/chat/v1/providers").to_return(
      body: { data: [{ is_default: true, default_model: "test-model-high" }] }.to_json,
    )
  end

  def stub_models
    stub_request(:get, "http://agent.test/chat/v1/models").with(
      headers: {
        "Authorization" => "Bearer private-token",
      },
    ).to_return(
      body: {
        data: [{ id: "test-model", reasoning_efforts: %w[low high], private_key: "hidden" }],
      }.to_json,
    )
  end

  describe "launcher runtime" do
    it "lists choices for the chosen agent and rejects access to another owner's agent" do
      stub_models
      sign_in(owner)
      get "/second-brain/agent-runtime.json", params: { agent: bot.username }
      expect(response.status).to eq(200)
      expect(response.parsed_body["models"]).to eq(
        [{ "id" => "test-model", "efforts" => %w[low high] }],
      )

      expect(response.parsed_body["defaults"]).to eq(
        "model" => "test-model",
        "reasoning_effort" => "high",
      )

      private_bot = Fabricate(:user)
      SecondBrain::AgentRecord.create!(
        bot_user_id: private_bot.id,
        owner_user_id: other.id,
        term_llm_url: "http://private.test",
        term_llm_token: "hidden",
        forum_role: "tl4",
      )
      get "/second-brain/agent-runtime.json", params: { agent: private_bot.username }
      expect(response.status).to eq(403)
    end

    it "uses the plugin's configured model and its advertised default effort" do
      SiteSetting.second_brain_term_llm_model = "custom-model"
      stub_request(:get, "http://agent.test/chat/v1/models").to_return(
        body: {
          data: [
            {
              id: "custom-model",
              reasoning_efforts: %w[low high],
              default_reasoning_effort: "low",
            },
          ],
        }.to_json,
      )
      sign_in(owner)

      get "/second-brain/agent-runtime.json", params: { agent: bot.username }

      expect(response.status).to eq(200)
      expect(response.parsed_body["defaults"]).to eq(
        "model" => "custom-model",
        "reasoning_effort" => "low",
      )
      expect(response.parsed_body["model"]).to eq("")
    end

    it "keeps model choices available when defaults cannot be discovered" do
      stub_models
      stub_request(:get, "http://agent.test/chat/v1/providers").to_return(status: 404)
      sign_in(owner)

      get "/second-brain/agent-runtime.json", params: { agent: bot.username }

      expect(response.status).to eq(200)
      expect(response.parsed_body["defaults"]).to eq({})
      expect(response.parsed_body["models"]).to eq(
        [{ "id" => "test-model", "efforts" => %w[low high] }],
      )
    end

    it "saves the selection before the first post-created event and keeps it on the topic" do
      stub_models
      sign_in(owner)
      observed = nil
      listener =
        proc do |post, *|
          if post.user_id == owner.id
            observed =
              post.topic.reload.custom_fields.slice(
                "second_brain_model",
                "second_brain_reasoning_effort",
              )
          end
        end
      DiscourseEvent.on(:post_created, &listener)

      post "/second-brain/chats.json",
           params: {
             message: "Launcher model test",
             agent: bot.username,
             model: "test-model",
             reasoning_effort: "high",
           }

      expect(response.status).to eq(200)
      expect(observed).to eq(
        "second_brain_model" => "test-model",
        "second_brain_reasoning_effort" => "high",
      )
      chat = Topic.find_by(user_id: owner.id, title: "Launcher model test")
      trigger = chat.posts.find_by(user_id: owner.id)
      stub_request(
        :get,
        "http://agent.test/chat/v1/sessions/sb_#{chat.id}_#{trigger.id}/state",
      ).to_return(body: "{}")
      get "/second-brain/chats/#{chat.id}/runtime.json"
      expect(response.parsed_body).to include("model" => "test-model", "reasoning_effort" => "high")
    ensure
      DiscourseEvent.off(:post_created, &listener) if listener
    end

    it "does not create a conversation with an invalid selection" do
      stub_models
      sign_in(owner)
      expect do
        post "/second-brain/chats.json",
             params: {
               message: "Invalid launcher model",
               agent: bot.username,
               model: "test-model",
               reasoning_effort: "invalid",
             }
      end.not_to change(Topic, :count)
      expect(response.status).to eq(400)
    end

    it "can still start with defaults when model discovery is unavailable" do
      sign_in(owner)
      post "/second-brain/chats.json",
           params: {
             message: "Default launcher model",
             agent: bot.username,
           }
      expect(response.status).to eq(200)
      chat = Topic.find_by(user_id: owner.id, title: "Default launcher model")
      expect(chat.custom_fields["second_brain_model"]).to be_blank
    end
  end

  describe "#runtime" do
    it "returns model choices and recorded reply metadata without credentials" do
      stub_models
      reply = Fabricate(:post, topic: topic, user: bot)
      reply.custom_fields["second_brain_runtime"] = {
        model: "old-model",
        reasoning_effort: "high",
      }.to_json
      reply.save_custom_fields(true)
      sign_in(owner)

      get path

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq(
        "model" => "",
        "reasoning_effort" => "",
        "models" => [{ "id" => "test-model", "efforts" => %w[low high] }],
        "defaults" => {
          "model" => "test-model",
          "reasoning_effort" => "high",
        },
        "last_reply" => {
          "model" => "old-model",
          "reasoning_effort" => "high",
        },
      )

      get "/t/#{topic.id}.json"
      post_data =
        response.parsed_body.dig("post_stream", "posts").find { |post| post["id"] == reply.id }
      expect(post_data["second_brain_runtime"]).to eq(
        "model" => "old-model",
        "reasoning_effort" => "high",
      )
    end

    it "can inspect the last run of an older conversation" do
      stub_models
      trigger = Fabricate(:post, topic: topic, user: owner)
      Fabricate(:post, topic: topic, user: bot, reply_to_post_number: trigger.post_number)
      stub_request(
        :get,
        "http://agent.test/chat/v1/sessions/sb_#{topic.id}_#{trigger.id}/state",
      ).with(headers: { "Authorization" => "Bearer private-token" }).to_return(
        body: { model: "legacy-model", secret: "hidden" }.to_json,
      )
      sign_in(owner)

      get path

      expect(response.status).to eq(200)
      expect(response.parsed_body["last_reply"]).to eq("model" => "legacy-model")
    end

    it "returns a generic error when the agent is unavailable" do
      stub_request(:get, "http://agent.test/chat/v1/models").to_raise(Errno::ECONNREFUSED)
      sign_in(owner)
      get path
      expect(response.status).to eq(502)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("second_brain.errors.runtime_unavailable"),
      )
    end
  end

  describe "#update_runtime" do
    it "persists the conversation selection and can reset it without contacting the agent" do
      upstream = stub_models
      sign_in(owner)
      put path, params: { model: "test-model", reasoning_effort: "high" }
      expect(response.status).to eq(200)
      expect(topic.reload.custom_fields["second_brain_model"]).to eq("test-model")
      expect(topic.custom_fields["second_brain_reasoning_effort"]).to eq("high")

      put path, params: { model: "", reasoning_effort: "" }
      expect(response.status).to eq(200)
      expect(topic.reload.custom_fields["second_brain_model"]).to be_blank
      expect(topic.custom_fields["second_brain_reasoning_effort"]).to be_blank
      expect(upstream).to have_been_requested.once
    end

    it "rejects unsupported models and efforts without saving" do
      stub_models
      sign_in(owner)
      [%w[unknown high], %w[test-model invalid], ["", "high"]].each do |model, effort|
        put path, params: { model: model, reasoning_effort: effort }
        expect(response.status).to eq(400)
        expect(topic.reload.custom_fields["second_brain_model"]).to be_blank
      end
    end
  end

  describe "runtime authorization" do
    it "blocks anonymous and non-participant access before contacting the agent" do
      [nil, other].each do |user|
        sign_in(user) if user
        get path
        expect(response.status).to be_in([403, 404])
        put path, params: { model: "test-model" }
        expect(response.status).to be_in([403, 404])
      end
    end

    it "blocks human PMs and another member's personal agent, even when invited" do
      personal_bot = Fabricate(:user)
      SecondBrain::AgentRecord.create!(
        bot_user_id: personal_bot.id,
        owner_user_id: other.id,
        term_llm_url: "http://personal.test",
        term_llm_token: "private",
        forum_role: "tl4",
      )
      sign_in(owner)
      [other, personal_bot].each do |recipient|
        chat = Fabricate(:private_message_topic, user: owner, recipient: recipient)
        get "/second-brain/chats/#{chat.id}/runtime.json"
        expect(response.status).to eq(403)
        put "/second-brain/chats/#{chat.id}/runtime.json", params: { model: "test-model" }
        expect(response.status).to eq(403)
      end
    end
  end
end
