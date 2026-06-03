# frozen_string_literal: true

require "rails_helper"

describe Jobs::SecondBrainWatchdog do
  before do
    SiteSetting.second_brain_enabled = true
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "fam-token"
  end

  fab!(:human, :user)
  let(:bot) { SecondBrain::Bot.user }
  let(:topic) { Fabricate(:private_message_topic, user: human, recipient: bot) }

  let(:ask_field) { SecondBrain::BotResponder::ASK_FIELD }
  let(:state_field) { SecondBrain::BotResponder::STATE_FIELD }
  let(:thinking) { I18n.t("second_brain.thinking") }
  let(:interrupted) { I18n.t("second_brain.askuser.interrupted") }

  def run!
    described_class.new.execute({})
  end

  it "finalizes a placeholder stranded on 'Thinking…' past the threshold" do
    placeholder = SecondBrain::BotResponder.ensure_placeholder(topic)
    placeholder.update_columns(updated_at: 1.hour.ago)

    run!

    expect(placeholder.reload.raw).to include(interrupted)
  end

  it "never calls term-llm (cannot re-poke a stuck run / loop)" do
    placeholder = SecondBrain::BotResponder.ensure_placeholder(topic)
    placeholder.update_columns(updated_at: 1.hour.ago)

    run!

    expect(WebMock).not_to have_requested(:any, %r{termllm\.test})
  end

  it "leaves a fresh (in-flight) placeholder alone" do
    placeholder = SecondBrain::BotResponder.ensure_placeholder(topic)

    run!

    expect(placeholder.reload.raw).to eq(thinking)
  end

  it "leaves a PENDING (unanswered) question alone — it waits for the member" do
    post = Fabricate(:post, topic: topic, user: bot)
    post.update_columns(raw: "A partial answer streamed before stan paused.", updated_at: 1.hour.ago)
    post.custom_fields[ask_field] = { "status" => "pending", "call_id" => "c1" }.to_json
    post.custom_fields[state_field] = { "session_id" => "s", "response_id" => "r", "last_seq" => 1 }.to_json
    post.save_custom_fields(true)

    run!

    post.reload
    expect(JSON.parse(post.custom_fields[ask_field])["status"]).to eq("pending")
    expect(post.custom_fields[state_field]).to be_present
  end

  it "reconciles a resume answered but never finalized, preserving partial content" do
    post = Fabricate(:post, topic: topic, user: bot)
    post.update_columns(raw: "Partial answer before the pause.", updated_at: 1.hour.ago)
    post.custom_fields[ask_field] = { "status" => "answered", "call_id" => "c1" }.to_json
    post.custom_fields[state_field] = { "session_id" => "s", "response_id" => "r", "last_seq" => 1 }.to_json
    post.save_custom_fields(true)

    run!

    post.reload
    expect(post.raw).to include("Partial answer before the pause.") # preserved
    expect(post.raw).to include(interrupted)
    expect(JSON.parse(post.custom_fields[ask_field])["status"]).to eq("interrupted")
    expect(post.custom_fields[state_field]).to be_nil # lingering state dropped
  end

  it "leaves a freshly-answered resume alone (its clock restarts at answer time)" do
    post = Fabricate(:post, topic: topic, user: bot)
    post.custom_fields[ask_field] = { "status" => "answered", "call_id" => "c1" }.to_json
    post.custom_fields[state_field] = { "session_id" => "s", "response_id" => "r", "last_seq" => 1 }.to_json
    post.save_custom_fields(true)
    post.update_columns(updated_at: 2.minutes.ago) # just answered — resume in flight

    run!

    post.reload
    expect(JSON.parse(post.custom_fields[ask_field])["status"]).to eq("answered")
    expect(post.custom_fields[state_field]).to be_present
  end

  it "does not reconcile within the idle-timeout-derived cutoff (a long silent tool is still live)" do
    SiteSetting.second_brain_stream_idle_timeout = 3600 # cutoff -> max(30m, ~2h5m)
    placeholder = SecondBrain::BotResponder.ensure_placeholder(topic)
    placeholder.update_columns(updated_at: 90.minutes.ago) # stale by 90m, but < derived cutoff

    run!

    expect(placeholder.reload.raw).to eq(thinking) # untouched — could be a live silent tool
  end

  it "reconcile_stranded! bails without clobbering a post that is no longer stranded" do
    post = Fabricate(:post, topic: topic, user: bot)
    post.update_columns(raw: "The real finished answer.")

    expect(SecondBrain::BotResponder.new(post).reconcile_stranded!).to eq(false)
    expect(post.reload.raw).to eq("The real finished answer.")
  end
end
