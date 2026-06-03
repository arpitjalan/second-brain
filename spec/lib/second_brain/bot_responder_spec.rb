# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/term_llm_sse"

describe SecondBrain::BotResponder do
  include TermLlmSseHelpers

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

  # End-to-end streaming: drive respond! against a scripted fake term-llm SSE.
  describe "#respond! (reply flow)" do
    before do
      # Skip the auto-title round-trip (its own HTTP call) so these focus on the
      # reply; titling is covered separately.
      topic.custom_fields["second_brain_titled"] = true
      topic.save_custom_fields
    end

    let(:bot_reply) { topic.reload.posts.find_by(user_id: bot.id) }

    it "streams a plain answer and finalizes the placeholder with it" do
      stub_termllm_respond(body: sse_delta("Hello ") + sse_delta("there", seq: 2) + sse_done)

      messages = MessageBus.track_publish("/second-brain/stream") { described_class.new(human_post).respond! }

      expect(bot_reply.raw).to eq("Hello there")
      expect(messages.last.data[:done]).to eq(true)
    end

    it "renders tool calls as a collapsible summary above the answer" do
      body =
        sse_tool_start(call_id: "t1", name: "web_search", args: { "query" => "weather" }, seq: 1) +
          sse_tool_end(call_id: "t1", success: true, seq: 2) +
          sse_delta("It is sunny.", seq: 3) +
          sse_done
      stub_termllm_respond(body: body)

      described_class.new(human_post).respond!

      expect(bot_reply.raw).to include("[details")
      expect(bot_reply.raw).to include("web_search")
      expect(bot_reply.raw).to include("weather")
      expect(bot_reply.raw).to include("It is sunny.")
    end

    it "replies exactly once when two jobs race for the same post (claim_turn!)" do
      stub_termllm_respond(body: sse_delta("Answer", seq: 1) + sse_done)

      described_class.new(human_post).respond!
      described_class.new(human_post).respond! # duplicate job — must no-op

      expect(topic.reload.posts.where(user_id: bot.id).count).to eq(1)
      expect(bot_reply.raw).to eq("Answer")
      expect(a_request(:post, "http://termllm.test/chat/v1/responses")).to have_been_made.once
    end

    it "finalizes with the friendly failure message when term-llm errors" do
      stub_termllm_respond(status: 500, body: "boom")

      described_class.new(human_post).respond!

      expect(bot_reply.raw).to include(reply_failed)
    end

    it "writes the final answer to the DB once" do
      stub_termllm_respond(body: sse_delta("Done.", seq: 1) + sse_done)

      Post.any_instance.expects(:update_columns).with(has_key(:raw)).once.returns(true)
      Post.any_instance.stubs(:rebake!)

      described_class.new(human_post).respond!
    end

    it "auto-titles the chat from the first message on completion" do
      topic.custom_fields.delete("second_brain_titled")
      topic.save_custom_fields
      stub_termllm_respond(body: sse_delta("Hi.", seq: 1) + sse_done)
      stub_termllm_title(title: "Boiler Warranty Question")

      described_class.new(human_post).respond!

      expect(topic.reload.title).to eq("Boiler Warranty Question")
    end
  end

  # The full pause → answer → resume round-trip, including the regression that
  # pre-pause text AND tools survive into the resumed continuation (TODO #3).
  describe "#resume! (ask_user round-trip)" do
    before do
      topic.custom_fields["second_brain_titled"] = true
      topic.save_custom_fields
    end

    # Run respond! to the point it pauses on an ask_user prompt, then mark the
    # prompt answered the way the answer controller does, and return the bot post.
    def pause_then_answer(question_call_id: "c1")
      body =
        sse_created("resp_1", seq: 1) +
          sse_tool_start(call_id: "t1", name: "web_search", args: { "query" => "x" }, seq: 2) +
          sse_tool_end(call_id: "t1", success: true, seq: 3) +
          sse_delta("Before the question. ", seq: 4) +
          sse_ask_user(call_id: question_call_id, questions: [{ "header" => "Color" }], seq: 5)
      stub_termllm_respond(body: body)
      described_class.new(human_post).respond!

      post = topic.reload.posts.find_by(user_id: bot.id)
      state = JSON.parse(post.custom_fields[described_class::ASK_FIELD])
      state["status"] = "answered" # what ChatsController#answer stamps post-submit
      post.custom_fields[described_class::ASK_FIELD] = state.to_json
      post.save_custom_fields(true)
      post
    end

    it "pauses on ask_user with the pre-pause text + tools shown and state persisted" do
      post = pause_then_answer

      expect(post.raw).to include("Before the question.")
      expect(post.raw).to include("web_search") # pre-pause tool summary
      public_state = JSON.parse(post.custom_fields[described_class::ASK_FIELD])
      expect(public_state["call_id"]).to eq("c1")
      server_state = JSON.parse(post.custom_fields[described_class::STATE_FIELD])
      expect(server_state["response_id"]).to eq("resp_1")
      expect(server_state["last_seq"]).to eq(5)
    end

    it "resumes, preserving pre-pause text AND tools alongside the continuation" do
      post = pause_then_answer
      stub_termllm_events(
        response_id: "resp_1",
        after: 5,
        body: sse_delta("After the answer.", seq: 6) + sse_done,
      )

      described_class.new(post).resume!

      post.reload
      expect(post.raw).to include("Before the question.") # pre-pause text
      expect(post.raw).to include("After the answer.") # continuation
      expect(post.raw).to include("web_search") # pre-pause tools (the regression)
      expect(JSON.parse(post.custom_fields[described_class::ASK_FIELD])["status"]).to eq("done")
      expect(post.custom_fields[described_class::STATE_FIELD]).to be_nil # dropped on finish
    end

    it "pauses again when the continuation asks a second question, keeping all prior tools" do
      post = pause_then_answer
      stub_termllm_events(
        response_id: "resp_1",
        after: 5,
        body:
          sse_delta("Mid. ", seq: 6) +
            sse_tool_start(call_id: "t2", name: "read_url", args: { "url" => "http://x" }, seq: 7) +
            sse_tool_end(call_id: "t2", success: true, seq: 8) +
            sse_ask_user(call_id: "c2", questions: [{ "header" => "Size" }], seq: 9),
      )

      described_class.new(post).resume!

      post.reload
      public_state = JSON.parse(post.custom_fields[described_class::ASK_FIELD])
      expect(public_state["status"]).to eq("pending")
      expect(public_state["call_id"]).to eq("c2")
      expect(post.raw).to include("web_search") # first round's tool
      expect(post.raw).to include("read_url") # second round's tool
    end

    it "finalizes with an interrupted note if the continuation fails" do
      post = pause_then_answer
      stub_termllm_events(response_id: "resp_1", after: 5, status: 500, body: "boom")

      described_class.new(post).resume!

      post.reload
      expect(post.raw).to include("Before the question.")
      expect(post.raw).to include(I18n.t("second_brain.askuser.interrupted"))
      expect(JSON.parse(post.custom_fields[described_class::ASK_FIELD])["status"]).to eq("interrupted")
    end

    it "resumes only once when two resume jobs race (claim_resume!)" do
      post = pause_then_answer
      stub_termllm_events(
        response_id: "resp_1",
        after: 5,
        body: sse_delta("Final.", seq: 6) + sse_done,
      )

      described_class.new(post).resume!
      described_class.new(post.reload).resume! # duplicate — must no-op (claim + status)

      expect(a_request(:get, "http://termllm.test/chat/v1/responses/resp_1/events?after=5")).to(
        have_been_made.once,
      )
    end
  end
end
