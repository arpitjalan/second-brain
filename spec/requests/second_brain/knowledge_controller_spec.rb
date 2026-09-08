# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecondBrain::KnowledgeController do
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other, :user)
  fab!(:category)
  let(:bot) { SecondBrain::Bot.user }
  let(:chat) { Fabricate(:private_message_topic, user: owner, recipient: bot) }
  let(:second_chat) { Fabricate(:private_message_topic, user: owner, recipient: bot) }
  let(:source_ids) { [chat.id, second_chat.id] }

  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://agent.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "private-token"
    SiteSetting.second_brain_public_category = category.id.to_s
  end

  describe "#draft" do
    it "sends all 15 posts from two conversations, with tools disabled, without creating a topic" do
      originals =
        15.times.map do |index|
          Fabricate(
            :post,
            topic: index < 8 ? chat : second_chat,
            user: index.even? ? owner : bot,
            raw: "Inventory decision #{index}: keep record number #{index} in the agreed folder.",
          )
        end
      hidden =
        Fabricate(:post, topic: chat, user: bot, hidden: true, raw: "Hidden inventory information")
      pending = Fabricate(:post, topic: chat, user: bot, raw: I18n.t("second_brain.thinking"))
      captured = nil
      stub_request(:post, "http://agent.test/chat/v1/chat/completions")
        .with do |request|
          captured = JSON.parse(request.body)
          request.headers["Authorization"] == "Bearer private-token"
        end
        .to_return(
          body:
            "data: #{{ choices: [{ delta: { content: "# Inventory reference\n\n## Decisions\n\nA consolidated reference with open questions." } }] }.to_json}\n\ndata: [DONE]\n\n",
        )
      sign_in(owner)

      expect do
        post "/second-brain/knowledge/draft.json",
             params: {
               topic_ids: source_ids,
               agent: bot.username,
             }
      end.not_to change(Topic, :count)

      expect(response.status).to eq(202)
      expect(captured).to be_nil
      draft_id = response.parsed_body["draft_id"]
      Jobs::SecondBrainKnowledgeDraft.new.execute(user_id: owner.id, draft_id: draft_id)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.status).to eq(200)
      expect(captured["stream"]).to eq(true)
      expect(captured["tool_choice"]).to eq("none")
      transcript = JSON.parse(captured["messages"].last["content"])
      texts =
        transcript["conversations"].flat_map do |conversation|
          conversation["posts"].map { |post| post["text"] }
        end
      expect(texts).to match_array(originals.map(&:raw))
      expect(texts).not_to include(hidden.raw, pending.raw)
      expect(response.parsed_body["title"]).to eq("Inventory reference")
      expect(response.parsed_body["raw"]).to start_with("## Decisions")
      expect(response.parsed_body["visibility"]).to eq("private")
      expect(response.parsed_body["sources"].map { |source| source["id"] }).to eq(source_ids)
    end

    it "rejects an inaccessible source even when another selected source is accessible" do
      sign_in(other)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: source_ids,
             agent: bot.username,
           }
      expect(response.status).to eq(403)
    end

    it "rejects another owner's agent even when invited into its conversation" do
      personal_bot = Fabricate(:user)
      SecondBrain::AgentRecord.create!(
        bot_user_id: personal_bot.id,
        owner_user_id: other.id,
        term_llm_url: "http://private.test",
        term_llm_token: "secret",
        forum_role: "tl4",
      )
      personal_chat = Fabricate(:private_message_topic, user: owner, recipient: personal_bot)
      sign_in(owner)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: [personal_chat.id],
             agent: bot.username,
           }
      expect(response.status).to eq(403)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: [chat.id],
             agent: personal_bot.username,
           }
      expect(response.status).to eq(403)
    end

    it "rejects oversized transcripts and invalid selections without truncating" do
      2.times { Fabricate(:post, topic: chat, user: bot, raw: "Long note " * 3050) }
      sign_in(owner)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: [chat.id],
             agent: bot.username,
           }
      expect(response.status).to eq(422)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: [1, 2, 3, 4, 5, 6],
             agent: bot.username,
           }
      expect(response.status).to eq(400)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: ["invalid"],
             agent: bot.username,
           }
      expect(response.status).to eq(400)
    end

    it "reports an interrupted worker and does not restart the inference on redelivery" do
      Fabricate(:post, topic: chat, user: bot)
      stub_request(:post, "http://agent.test/chat/v1/chat/completions").to_raise(Sidekiq::Shutdown)
      sign_in(owner)
      post "/second-brain/knowledge/draft.json",
           params: {
             topic_ids: [chat.id],
             agent: bot.username,
           }
      draft_id = response.parsed_body["draft_id"]
      job = Jobs::SecondBrainKnowledgeDraft.new
      expect { job.execute(user_id: owner.id, draft_id: draft_id) }.to raise_error(
        Sidekiq::Shutdown,
      )
      job.execute(user_id: owner.id, draft_id: draft_id)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.parsed_body["status"]).to eq("failed")
      expect(response.parsed_body).not_to have_key("preview")
      expect(WebMock).to have_requested(:post, "http://agent.test/chat/v1/chat/completions").once
    end

    it "reports generation failure without creating a topic" do
      Fabricate(:post, topic: chat, user: bot)
      stub_request(:post, "http://agent.test/chat/v1/chat/completions").to_return(status: 503)
      sign_in(owner)
      expect do
        post "/second-brain/knowledge/draft.json",
             params: {
               topic_ids: [chat.id],
               agent: bot.username,
             }
      end.not_to change(Topic, :count)
      expect(response.status).to eq(202)
      draft_id = response.parsed_body["draft_id"]
      Jobs::SecondBrainKnowledgeDraft.new.execute(user_id: owner.id, draft_id: draft_id)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.parsed_body["status"]).to eq("failed")
    end
  end

  describe "#status" do
    it "keeps progress private and rechecks source access" do
      draft_id = SecureRandom.hex(16)
      SecondBrain::KnowledgeDraft.write(
        owner.id,
        draft_id,
        {
          status: "running",
          topic_ids: [chat.id],
          preview: "Private draft text",
          created_at: Time.now.to_i,
        },
      )
      sign_in(other)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.status).to eq(404)
      sign_in(owner)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.parsed_body).to include(
        "status" => "running",
        "preview" => "Private draft text",
      )
      chat.topic_allowed_users.find_by(user_id: owner.id).destroy!
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.status).to eq(403)
    end

    it "reports a stalled worker instead of polling forever" do
      draft_id = SecureRandom.hex(16)
      SecondBrain::KnowledgeDraft.write(
        owner.id,
        draft_id,
        { status: "running", topic_ids: [chat.id], created_at: 11.minutes.ago.to_i },
      )
      sign_in(owner)
      get "/second-brain/knowledge/drafts/#{draft_id}.json"
      expect(response.parsed_body["status"]).to eq("failed")
    end
  end

  describe "#create" do
    let(:attributes) do
      {
        topic_ids: source_ids,
        title: "Household inventory reference",
        raw: "Keep receipts, serial numbers and purchase dates together.",
        visibility: "private",
      }
    end
    before { sign_in(owner) }

    it "saves reviewed text privately with both source links and only the owner as participant" do
      source_ids
      expect { post "/second-brain/knowledge.json", params: attributes }.to change(
        Topic,
        :count,
      ).by(1)
      expect(response.status).to eq(201)
      note = Topic.order(:id).last
      expect(note).to be_private_message
      expect(note.topic_allowed_users.pluck(:user_id)).to eq([owner.id])
      expect(JSON.parse(note.custom_fields["second_brain_knowledge_sources"])).to eq(source_ids)
      expect(note.first_post.raw).to include(
        attributes[:raw],
        "/t/#{chat.id}",
        "/t/#{second_chat.id}",
      )
      expect(Guardian.new(other).can_see?(note)).to eq(false)
    end

    it "publishes the reviewed note while leaving source conversations private" do
      post "/second-brain/knowledge.json",
           params: attributes.merge(visibility: "shared", category_id: category.id)
      expect(response.status).to eq(201)
      note = Topic.order(:id).last
      expect(note).not_to be_private_message
      expect(note.category_id).to eq(category.id)
      expect(chat.reload).to be_private_message
      expect(second_chat.reload).to be_private_message
    end

    it "rechecks source and destination permissions when saving" do
      source_ids
      chat.topic_allowed_users.find_by(user_id: owner.id).destroy!
      expect { post "/second-brain/knowledge.json", params: attributes }.not_to change(
        Topic,
        :count,
      )
      expect(response.status).to eq(403)
      category.set_permissions(staff: :full)
      category.save!
      expect do
        post "/second-brain/knowledge.json",
             params:
               attributes.merge(
                 topic_ids: [second_chat.id],
                 visibility: "shared",
                 category_id: category.id,
               )
      end.not_to change(Topic, :count)
      expect(response.status).to eq(403)
    end

    it "rejects arbitrary non-chat topics and invalid visibility" do
      ordinary = Fabricate(:topic)
      post "/second-brain/knowledge.json", params: attributes.merge(topic_ids: [ordinary.id])
      expect(response.status).to eq(403)
      post "/second-brain/knowledge.json", params: attributes.merge(visibility: "everyone")
      expect(response.status).to eq(400)
    end
  end
end
