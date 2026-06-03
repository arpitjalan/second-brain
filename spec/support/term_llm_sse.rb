# frozen_string_literal: true

# Test helpers for scripting a fake term-llm over WebMock, so the streaming
# reply → ask_user → resume flow (BotResponder#respond! / #resume!) can be driven
# end-to-end without a real term-llm server.
#
# The frame format mirrors exactly what TermLlmClient#run_sse parses: SSE frames
# separated by a blank line, each with optional `id:` / `event:` / `data:` lines;
# `data:` is JSON except the literal `[DONE]` sentinel. The event names match the
# ones run_sse handles (response.created / .output_text.delta / .tool_exec.start /
# .tool_exec.end / .ask_user.prompt).
#
# Usage: `include TermLlmSseHelpers` in a describe block whose `before` sets
# `second_brain_term_llm_url` to "http://termllm.test/chat".
module TermLlmSseHelpers
  TERMLLM_BASE = "http://termllm.test/chat"

  # --- frame builders ---------------------------------------------------------

  def sse_frame(event: nil, data: nil, seq: nil, raw_data: nil)
    lines = []
    lines << "id: #{seq}" if seq
    lines << "event: #{event}" if event
    lines << "data: #{raw_data}" unless raw_data.nil?
    lines << "data: #{data.to_json}" if raw_data.nil? && !data.nil?
    "#{lines.join("\n")}\n\n"
  end

  def sse_created(id, seq: nil)
    sse_frame(event: "response.created", data: { "response" => { "id" => id } }, seq: seq)
  end

  def sse_delta(text, seq: nil)
    sse_frame(event: "response.output_text.delta", data: { "delta" => text }, seq: seq)
  end

  def sse_tool_start(call_id:, name:, args: {}, info: "", seq: nil)
    sse_frame(
      event: "response.tool_exec.start",
      data: {
        "call_id" => call_id,
        "tool_name" => name,
        "tool_arguments" => args.to_json,
        "tool_info" => info,
      },
      seq: seq,
    )
  end

  def sse_tool_end(call_id:, success: true, seq: nil)
    sse_frame(
      event: "response.tool_exec.end",
      data: { "call_id" => call_id, "success" => success },
      seq: seq,
    )
  end

  def sse_ask_user(call_id:, questions:, seq: nil)
    sse_frame(
      event: "response.ask_user.prompt",
      data: { "call_id" => call_id, "questions" => questions },
      seq: seq,
    )
  end

  def sse_done
    sse_frame(raw_data: "[DONE]")
  end

  # --- endpoint stubs ---------------------------------------------------------

  # Stub POST /v1/responses (stream_respond) with a scripted SSE body. Pass a
  # block instead for non-standard behavior (e.g. a connection reset).
  def stub_termllm_respond(body: nil, status: 200, &blk)
    stub = stub_request(:post, "#{TERMLLM_BASE}/v1/responses")
    return stub.to_return(&blk) if blk
    stub.to_return(
      status: status,
      body: body.to_s,
      headers: { "Content-Type" => "text/event-stream" },
    )
  end

  # Stub GET /v1/responses/<id>/events?after=<n> (stream_events resume reconnect).
  def stub_termllm_events(response_id:, after:, body: nil, status: 200)
    stub_request(
      :get,
      "#{TERMLLM_BASE}/v1/responses/#{response_id}/events?after=#{after}",
    ).to_return(
      status: status,
      body: body.to_s,
      headers: { "Content-Type" => "text/event-stream" },
    )
  end

  # Stub POST /v1/sessions/<sid>/ask_user (submit_ask_user).
  def stub_termllm_ask_user(session_id:, status: 200, body: { "status" => "ok", "summary" => "noted" })
    stub_request(:post, "#{TERMLLM_BASE}/v1/sessions/#{session_id}/ask_user").to_return(
      status: status,
      body: body.is_a?(String) ? body : body.to_json,
      headers: { "Content-Type" => "application/json" },
    )
  end

  # Stub POST /v1/chat/completions (the auto-title call).
  def stub_termllm_title(title: "Generated Title")
    stub_request(:post, "#{TERMLLM_BASE}/v1/chat/completions").to_return(
      status: 200,
      body: { "choices" => [{ "message" => { "content" => title } }] }.to_json,
      headers: { "Content-Type" => "application/json" },
    )
  end
end
