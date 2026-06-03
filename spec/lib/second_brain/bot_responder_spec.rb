# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::BotResponder do
  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "fam-token"
  end

  fab!(:human, :user)
  let(:bot) { SecondBrain::Bot.user }
  let(:topic) { Fabricate(:private_message_topic, user: human, recipient: bot) }
  let(:human_post) { Fabricate(:post, topic: topic, user: human) }
  let(:bot_post) { Fabricate(:post, topic: topic, user: bot) }

  let(:reply_failed) { I18n.t("second_brain.errors.reply_failed") }
  let(:thinking) { I18n.t("second_brain.thinking") }

  describe "#claim_resume!" do
    it "claims a call_id once, no-ops a duplicate, but allows a new call_id" do
      expect(described_class.new(bot_post).send(:claim_resume!, "call-1")).to eq(true)
      # A re-delivered/concurrent job for the SAME answered call_id must no-op.
      expect(described_class.new(bot_post).send(:claim_resume!, "call-1")).to eq(false)
      # A genuine next ask_user round (same post, new call_id) can still resume.
      expect(described_class.new(bot_post).send(:claim_resume!, "call-2")).to eq(true)
    end

    it "is scoped per post" do
      other_post = Fabricate(:post, topic: topic, user: bot)
      expect(described_class.new(bot_post).send(:claim_resume!, "call-1")).to eq(true)
      expect(described_class.new(other_post).send(:claim_resume!, "call-1")).to eq(true)
    end
  end

  describe "#abort_with_failure!" do
    it "finalizes the existing 'Thinking…' placeholder with the failure message (respond path)" do
      placeholder = described_class.ensure_placeholder(topic)
      described_class.new(human_post).abort_with_failure!(resume: false)
      expect(placeholder.reload.raw).to include(reply_failed)
    end

    it "finalizes the bot post with the failure message (resume path)" do
      described_class.new(bot_post).abort_with_failure!(resume: true)
      expect(bot_post.reload.raw).to include(reply_failed)
    end

    it "does not clobber a turn that already reached a terminal state" do
      placeholder = described_class.ensure_placeholder(topic)
      responder = described_class.new(human_post)
      responder.instance_variable_set(:@finalized, true)
      responder.abort_with_failure!(resume: false)
      expect(placeholder.reload.raw).to eq(thinking)
    end

    it "swallows a failure while finalizing rather than re-raising into the job" do
      responder = described_class.new(bot_post)
      responder.stubs(:finalize).raises(StandardError, "db down")
      expect { responder.abort_with_failure!(resume: true) }.not_to raise_error
    end
  end

  describe Jobs::SecondBrainReply do
    it "surfaces an unexpected error on the placeholder instead of leaving it on 'Thinking…'" do
      placeholder = SecondBrain::BotResponder.ensure_placeholder(topic)
      SecondBrain::BotResponder.any_instance.stubs(:respond!).raises(StandardError, "boom")

      described_class.new.execute(post_id: human_post.id)

      expect(placeholder.reload.raw).to include(reply_failed)
    end

    it "does not re-raise (no Sidekiq retry storm) on an unexpected error" do
      SecondBrain::BotResponder.ensure_placeholder(topic)
      SecondBrain::BotResponder.any_instance.stubs(:respond!).raises(StandardError, "boom")

      expect { described_class.new.execute(post_id: human_post.id) }.not_to raise_error
    end
  end
end
