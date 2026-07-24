# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::Agent do
  before do
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "fam-token"
    SiteSetting.second_brain_term_llm_model = "gpt-test"
  end

  let(:family_bot) { SecondBrain::Bot.user }

  describe ".family" do
    it "is built from the global settings + the bot user, and is shared" do
      fam = described_class.family
      expect(fam.user).to eq(family_bot)
      expect(fam.url).to eq("http://termllm.test/chat")
      expect(fam.token).to eq("fam-token")
      expect(fam.model).to eq("gpt-test")
      expect(fam).to be_shared
      expect(fam.forum_role).to eq(:admin)
    end
  end

  describe "with an empty registry (behaviour-neutral)" do
    it "resolves only the family bot" do
      expect(described_class.resolve(family_bot).user).to eq(family_bot)
      expect(described_class.resolve(Fabricate(:user))).to be_nil
    end

    it "all == [family]" do
      expect(described_class.all.map(&:user)).to eq([family_bot])
      expect(described_class.bot_user_ids).to eq([family_bot.id])
    end
  end

  describe "with a personal agent in the registry" do
    fab!(:owner, :user)
    fab!(:bot) { Fabricate(:user, username: "stan_arpit") }

    let!(:row) do
      SecondBrain::AgentRecord.create!(
        bot_user_id: bot.id,
        term_llm_url: "http://personal.test/chat",
        term_llm_token: "pers-token",
        model: "gpt-personal",
        owner_user_id: owner.id,
        forum_role: "tl4",
      )
    end

    it "resolves the personal agent from its row" do
      agent = described_class.resolve(bot)
      expect(agent.url).to eq("http://personal.test/chat")
      expect(agent.token).to eq("pers-token")
      expect(agent.model).to eq("gpt-personal")
      expect(agent.owner_user_id).to eq(owner.id)
      expect(agent.forum_role).to eq(:tl4)
      expect(agent).not_to be_shared
    end

    it "includes both bots in all + bot_user_ids" do
      expect(described_class.bot_user_ids).to contain_exactly(family_bot.id, bot.id)
    end

    it "is owned_by / available_to the owner only" do
      expect(described_class.owned_by(owner).map(&:user)).to eq([bot])
      expect(described_class.owned_by(Fabricate(:user))).to be_empty

      expect(described_class.available_to(owner).map(&:user)).to contain_exactly(family_bot, bot)
      expect(described_class.available_to(Fabricate(:user)).map(&:user)).to eq([family_bot])
    end

    it "uses the agent's endpoint/token/model on its client" do
      client = described_class.resolve(bot).client
      expect(client.send(:base_url)).to eq("http://personal.test/chat")
    end

    it "usable_by? — family serves anyone; a personal agent only its owner" do
      family = described_class.family
      personal = described_class.resolve(bot)
      stranger = Fabricate(:user)

      expect(family).to be_usable_by(owner)
      expect(family).to be_usable_by(stranger)
      expect(personal).to be_usable_by(owner)
      expect(personal).not_to be_usable_by(stranger)
      expect(personal).not_to be_usable_by(nil)
    end

    it "widget_proxy_prefix — family keeps the legacy path; a personal agent is scoped" do
      expect(described_class.family.widget_proxy_prefix).to eq("/second-brain/widgets/")
      expect(described_class.resolve(bot).widget_proxy_prefix).to eq(
        "/second-brain/agent-widgets/stan_arpit/",
      )
    end
  end

  describe "AgentRecord validations" do
    fab!(:some_bot) { Fabricate(:user, username: "stan_two") }

    it "requires a term-llm url and token (a registry row has no global-settings fallback)" do
      row =
        SecondBrain::AgentRecord.new(bot_user_id: some_bot.id, owner_user_id: family_bot.id, forum_role: "tl4")
      expect(row).not_to be_valid
      expect(row.errors.attribute_names).to include(:term_llm_url, :term_llm_token)
    end
  end

  describe ".for_topic" do
    fab!(:human, :user)

    it "finds the agent bot participating in a PM" do
      topic = Fabricate(:private_message_topic, user: human, recipient: family_bot)
      expect(described_class.for_topic(topic).user).to eq(family_bot)
    end

    it "returns nil for a PM with no agent participant" do
      topic = Fabricate(:private_message_topic, user: human, recipient: Fabricate(:user))
      expect(described_class.for_topic(topic)).to be_nil
    end
  end
end
