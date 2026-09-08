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
        headers: {
          "Content-Type" => "text/event-stream",
        },
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
        headers: {
          "Content-Type" => "text/event-stream",
        },
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

  describe "#stream_respond (409 is NOT a replay eviction)" do
    it "raises a plain Error, not SnapshotRequired, on a 409 to POST /v1/responses" do
      # A 409 on the POST path is a session-limit condition, not the events-replay
      # eviction that SnapshotRequired signals — don't mislabel it.
      stub_termllm_respond(status: 409, body: "")

      expect { client.stream_respond([{ role: "user", content: "x" }]) }.to raise_error(
        SecondBrain::TermLlmClient::Error,
      ) { |e| expect(e).not_to be_a(SecondBrain::TermLlmClient::SnapshotRequired) }
    end
  end

  describe "#stream_respond (SSE parsing)" do
    it "sends explicit runtime overrides and captures the final reported model and effort" do
      SiteSetting.second_brain_term_llm_model = "agent-default"
      body =
        sse_frame(
          event: "response.created",
          data: {
            response: {
              id: "r1",
              model: "initial",
              reasoning_effort: "high",
            },
          },
        ) + sse_delta("answer") +
          sse_frame(
            event: "response.completed",
            data: {
              response: {
                id: "r1",
                model: "final",
                reasoning_effort: "low",
                secret: "hidden",
              },
            },
          ) + sse_done
      stub =
        stub_termllm_respond(body: body).with(
          body: hash_including("model" => "selected", "reasoning_effort" => "high"),
        )

      result =
        client.stream_respond(
          [{ role: "user", content: "x" }],
          model: "selected",
          reasoning_effort: "high",
        )

      expect(result[:runtime]).to eq("model" => "final", "reasoning_effort" => "low")
      expect(result[:text]).to eq("answer")
      expect(stub).to have_been_requested
    end

    it "leaves effort unspecified and preserves the agent model when no conversation override exists" do
      SiteSetting.second_brain_term_llm_model = "agent-default"
      stub =
        stub_termllm_respond(body: sse_done).with do |request|
          data = JSON.parse(request.body)
          data["model"] == "agent-default" && !data.key?("reasoning_effort")
        end

      client.stream_respond([{ role: "user", content: "x" }])
      expect(stub).to have_been_requested
    end

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
          sse_delta("answer", seq: 2) + sse_done
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:tools]).to be_empty
      expect(result[:text]).to eq("answer")
    end

    it "captures a response.failed run (does not present it as a normal reply)" do
      body =
        sse_created("r1", seq: 1) + sse_delta("partial", seq: 2) +
          sse_failed(message: "upstream 529", type: "overloaded", seq: 3) + sse_done
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:text]).to eq("partial") # partial content preserved
      expect(result[:error]).to include(type: "overloaded", message: "upstream 529")
    end

    it "captures a response.cancelled run" do
      body = sse_delta("half", seq: 1) + sse_cancelled(seq: 2) + sse_done
      stub_termllm_respond(body: body)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:error][:type]).to eq("cancelled")
    end

    it "leaves error nil on a clean run" do
      stub_termllm_respond(body: sse_delta("done", seq: 1) + sse_done)

      result = client.stream_respond([{ role: "user", content: "x" }])

      expect(result[:error]).to be_nil
    end

    it "fires the heartbeat on a keepalive ping (no content), so a silent run stays live" do
      # A ping produces no on_update (no text/tools), so without a per-chunk
      # heartbeat the post's updated_at would go stale and the watchdog could
      # reconcile a live turn. The heartbeat must fire on the ping chunk itself.
      stub_termllm_respond(body: sse_ping + sse_done)
      beats = 0

      result = client.stream_respond([{ role: "user", content: "x" }], heartbeat: -> { beats += 1 })

      expect(result[:text]).to eq("") # nothing streamed…
      expect(beats).to be >= 1 # …but the run was still marked alive
    end

    it "still runs with no heartbeat callback (backward compatible)" do
      stub_termllm_respond(body: sse_delta("hi", seq: 1) + sse_done)

      expect(client.stream_respond([{ role: "user", content: "x" }])[:text]).to eq("hi")
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

      expect {
        client.submit_ask_user(session_id: "s1", call_id: "c1", answers: [])
      }.to raise_error(SecondBrain::TermLlmClient::Expired)
    end

    it "raises Error on other non-2xx" do
      stub_termllm_ask_user(session_id: "s1", status: 500)

      expect {
        client.submit_ask_user(session_id: "s1", call_id: "c1", answers: [])
      }.to raise_error(SecondBrain::TermLlmClient::Error)
    end

    it "does NOT silently advance the run on a 200 with a non-JSON body" do
      stub_termllm_ask_user(session_id: "s1", body: "not json")

      expect {
        client.submit_ask_user(session_id: "s1", call_id: "c1", answers: [])
      }.to raise_error(SecondBrain::TermLlmClient::Error, /invalid JSON/)
    end
  end
end
