# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/term_llm_sse"

describe SecondBrain::TermLlmClient do
  include TermLlmSseHelpers

  before do
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "tok"
  end

  let(:client) { SecondBrain::Agent.family.client }

  describe "#stream_events (resume reconnect)" do
    it "returns the reconnected response_id even when the stream omits response.created" do
      # A reconnect's continuation does NOT re-emit `response.created`; the result
      # must still carry the id we reconnected to, or the next ask_user round loses
      # the run (resume! bails on a blank response_id → the post hangs).
      sse = +""
      sse << "id: 5\nevent: response.output_text.delta\ndata: {\"delta\":\"continued answer\"}\n\n"
      sse << "data: [DONE]\n\n"
      stub_request(:get, "http://termllm.test/chat/v1/responses/resp_abc/events?after=2").to_return(
        status: 200,
        body: sse,
        headers: { "Content-Type" => "text/event-stream" },
      )

      result = client.stream_events(response_id: "resp_abc", after: 2)

      expect(result[:response_id]).to eq("resp_abc")
      expect(result[:text]).to eq("continued answer")
      expect(result[:last_seq]).to eq(5)
    end

    it "still prefers a fresh response.created id if the continuation emits one" do
      sse = +""
      sse << "id: 6\nevent: response.created\ndata: {\"response\":{\"id\":\"resp_new\"}}\n\n"
      sse << "data: [DONE]\n\n"
      stub_request(:get, "http://termllm.test/chat/v1/responses/resp_old/events?after=0").to_return(
        status: 200,
        body: sse,
        headers: { "Content-Type" => "text/event-stream" },
      )

      result = client.stream_events(response_id: "resp_old", after: 0)

      expect(result[:response_id]).to eq("resp_new")
    end

    it "maps a 409 on reconnect to SnapshotRequired (replay buffer evicted)" do
      stub_termllm_events(response_id: "resp_x", after: 0, status: 409, body: "")

      expect { client.stream_events(response_id: "resp_x", after: 0) }.to raise_error(
        SecondBrain::TermLlmClient::SnapshotRequired,
      )
    end
  end

  describe "#stream_respond (SSE parsing)" do
    it "parses a CRLF-framed stream (normalizes \\r\\n line endings)" do
      body =
        "id: 1\r\nevent: response.output_text.delta\r\ndata: {\"delta\":\"hi\"}\r\n\r\n" \
          "data: [DONE]\r\n\r\n"
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:text]).to eq("hi")
    end

    it "accumulates tools and disconnects on an ask_user prompt (no [DONE])" do
      body =
        sse_created("r1", seq: 1) +
          sse_tool_start(call_id: "t1", name: "shell", args: { "command" => "ls" }, seq: 2) +
          sse_tool_end(call_id: "t1", success: true, seq: 3) +
          sse_ask_user(call_id: "c1", questions: [{ "header" => "Q" }], seq: 4)
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:response_id]).to eq("r1")
      expect(result[:tools].first).to include(name: "shell", done: true)
      expect(result[:ask_user][:call_id]).to eq("c1")
      expect(result[:last_seq]).to eq(4)
    end

    it "ignores the ask_user tool's own tool_exec frames (shown as a prompt, not a tool)" do
      body =
        sse_tool_start(call_id: "au", name: "ask_user", args: {}, seq: 1) +
          sse_delta("answer", seq: 2) +
          sse_done
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:tools]).to be_empty
      expect(result[:text]).to eq("answer")
    end
  end

  describe "#submit_ask_user" do
    it "returns the parsed body on 200" do
      stub_termllm_ask_user(session_id: "s1", body: { "status" => "ok", "summary" => "noted" })

      result = client.submit_ask_user(session_id: "s1", call_id: "c1", answers: [])

      expect(result["summary"]).to eq("noted")
    end

    it "raises Expired on 409 (already answered / run gone)" do
      stub_termllm_ask_user(session_id: "s1", status: 409)

      expect { client.submit_ask_user(session_id: "s1", call_id: "c1", answers: []) }.to raise_error(
        SecondBrain::TermLlmClient::Expired,
      )
    end

    it "raises Error on other non-2xx" do
      stub_termllm_ask_user(session_id: "s1", status: 500)

      expect { client.submit_ask_user(session_id: "s1", call_id: "c1", answers: []) }.to raise_error(
        SecondBrain::TermLlmClient::Error,
      )
    end

    it "does NOT silently advance the run on a 200 with a non-JSON body" do
      stub_termllm_ask_user(session_id: "s1", body: "not json")

      expect { client.submit_ask_user(session_id: "s1", call_id: "c1", answers: []) }.to raise_error(
        SecondBrain::TermLlmClient::Error,
        /invalid JSON/,
      )
    end
  end
end
