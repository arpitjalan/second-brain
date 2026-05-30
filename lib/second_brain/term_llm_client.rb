# frozen_string_literal: true

require "net/http"
require "uri"

module ::SecondBrain
  # Thin server-side client for a term-llm `serve` instance (which lives on a
  # different host and speaks an OpenAI-compatible API). The Bearer token is
  # read from site settings and never leaves the server.
  class TermLlmClient
    class Error < StandardError
    end

    class NotConfigured < Error
    end

    # The paused run is gone (term-llm restarted, or the 30m timeout fired) — the
    # ask_user answer can no longer be delivered.
    class Expired < Error
    end

    # A reconnect (events?after) can't replay: the run's event buffer evicted the
    # events we asked for. The resumed continuation is unrecoverable this way.
    class SnapshotRequired < Error
    end

    def self.configured?
      SiteSetting.second_brain_term_llm_url.present?
    end

    # Agentic, non-streaming reply via /v1/responses with server tools enabled.
    def respond(messages)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      body = {
        input: messages.map { |m| { type: "message", role: m[:role], content: m[:content] } },
        include_server_tools: true,
        stream: false,
      }
      model = SiteSetting.second_brain_term_llm_model
      body[:model] = model if model.present?

      extract_output_text(post_json("/v1/responses", body))
    end

    # Streaming agentic reply via /v1/responses (stream: true). Yields
    # (text, tools) on each update and returns a hash:
    #   { text:, tools:, ask_user:, response_id:, last_seq: }
    # If the agent calls the `ask_user` tool, `ask_user` is { call_id:, questions: }
    # and we disconnect (the run stays alive server-side, keyed by session_id).
    # `session_id` lets a later request answer/resume the run (see submit_ask_user).
    def stream_respond(messages, session_id: nil, &block)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      uri = parse_uri("#{base_url}/v1/responses")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request["session_id"] = session_id if session_id.present?
      auth(request)

      body = {
        input: messages.map { |m| { type: "message", role: m[:role], content: m[:content] } },
        include_server_tools: true,
        stream: true,
      }
      model = SiteSetting.second_brain_term_llm_model
      body[:model] = model if model.present?
      request.body = body.to_json

      run_sse(uri, request, &block)
    end

    # Reconnect to a (possibly paused-then-resumed) run and stream the events
    # after `after` (a sequence number). Used to stream the continuation once an
    # ask_user prompt has been answered. Same yield/return shape as stream_respond.
    def stream_events(response_id:, after:, &block)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      uri = parse_uri("#{base_url}/v1/responses/#{response_id}/events?after=#{after.to_i}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "text/event-stream"
      auth(request)

      run_sse(uri, request, &block)
    end

    # Answer (or cancel) a pending ask_user prompt, unblocking the paused run.
    # Returns the parsed response ({ "status", "answers", "summary" }).
    # Raises Expired on 404/409 (run gone / already answered).
    def submit_ask_user(session_id:, call_id:, answers: nil, cancelled: false)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      body = cancelled ? { call_id: call_id, cancelled: true } : { call_id: call_id, answers: answers }
      uri = parse_uri("#{base_url}/v1/sessions/#{session_id}/ask_user")
      http = build_http(uri, read_timeout: 30)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      auth(request)
      request.body = body.to_json

      response = http.request(request)
      case response.code.to_i
      when 200
        JSON.parse(response.body)
      when 404, 409
        raise Expired, "ask_user no longer pending (HTTP #{response.code})"
      else
        raise Error, "ask_user submit failed (HTTP #{response.code})"
      end
    rescue JSON::ParserError => e
      # A 200 with a non-JSON body must NOT silently advance the run as answered.
      raise Error, "invalid JSON from term-llm: #{e.message}"
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise Error, e.message
    end

    # Simpler non-agentic completion via /v1/chat/completions (used for titling).
    def complete(messages)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      body = { messages: messages, stream: false }
      model = SiteSetting.second_brain_term_llm_model
      body[:model] = model if model.present?

      response = post_json("/v1/chat/completions", body)
      response.dig("choices", 0, "message", "content").to_s
    end

    private

    # Consume an SSE stream (POST /v1/responses or GET …/events). Yields
    # (text, tools) as the answer/tools accumulate; returns the final hash. We
    # disconnect (throw) on an ask_user prompt or on [DONE].
    def run_sse(uri, request)
      http = build_http(uri, read_timeout: 600)

      text = +""
      tools = []
      buffer = +""
      ask_user = nil
      response_id = nil
      last_seq = 0

      begin
        catch(:sb_done) do
          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              # 409 from events?after = replay buffer evicted (unrecoverable here);
              # everything else is a generic/transient failure.
              if response.code.to_i == 409
                raise SnapshotRequired, "replay no longer available (HTTP 409)"
              end
              raise Error, "term-llm returned HTTP #{response.code}"
            end

            response.read_body do |chunk|
              buffer << chunk
              while (index = buffer.index("\n\n"))
                frame = buffer.slice!(0..index + 1)
                seq, event, data = parse_sse_frame(frame)
                last_seq = seq.to_i if seq
                throw :sb_done if data == "[DONE]"
                next if data.nil?

                case event
                when "response.created"
                  rid = (JSON.parse(data).dig("response", "id") rescue nil)
                  response_id = rid if rid
                when "response.output_text.delta"
                  delta = (JSON.parse(data)["delta"] rescue nil)
                  next if delta.nil?
                  text << delta
                  yield text, tools if block_given?
                when "response.tool_exec.start"
                  j = (JSON.parse(data) rescue {})
                  next if j["tool_name"].to_s == "ask_user" # not shown as a normal tool
                  args = (JSON.parse(j["tool_arguments"].to_s) rescue nil)
                  tools << {
                    call_id: j["call_id"],
                    name: j["tool_name"].to_s,
                    args: args.is_a?(Hash) ? args : {},
                    info: j["tool_info"].to_s,
                    done: false,
                    success: nil,
                  }
                  yield text, tools if block_given?
                when "response.tool_exec.end"
                  j = (JSON.parse(data) rescue {})
                  if (t = tools.find { |x| x[:call_id] == j["call_id"] })
                    t[:done] = true
                    t[:success] = j["success"]
                    yield text, tools if block_given?
                  end
                when "response.ask_user.prompt"
                  j = (JSON.parse(data) rescue {})
                  ask_user = { call_id: j["call_id"], questions: j["questions"] }
                  throw :sb_done # disconnect; the run stays alive server-side
                end
              end
            end
          end
        end
      rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
        raise Error, e.message
      end

      { text: text.strip, tools: tools, ask_user: ask_user, response_id: response_id, last_seq: last_seq }
    end

    # Parse one SSE frame into [id, event, data]. Frames are "id:"/"event:"/
    # "data:" lines; comments are ignored. `data` is nil when absent.
    def parse_sse_frame(frame)
      id = nil
      event = nil
      data_lines = []
      frame.each_line do |line|
        line = line.chomp
        if line.start_with?("id:")
          id = line.delete_prefix("id:").strip
        elsif line.start_with?("event:")
          event = line.delete_prefix("event:").strip
        elsif line.start_with?("data:")
          data_lines << line.delete_prefix("data:").strip
        end
      end
      [id, event, data_lines.empty? ? nil : data_lines.join("\n")]
    end

    # /v1/responses returns output[] items; collect text from message items.
    def extract_output_text(response)
      Array(response["output"])
        .filter_map do |item|
          next unless item["type"] == "message"

          Array(item["content"])
            .filter_map { |part| part["text"] if part["type"] == "output_text" }
            .join
        end
        .join("\n")
        .strip
    end

    def base_url
      SiteSetting.second_brain_term_llm_url.to_s.sub(%r{/+\z}, "")
    end

    # Parse a URL, turning a misconfigured term-llm URL into our own Error (so the
    # chat paints reply_failed) instead of an uncaught URI::InvalidURIError that
    # would leave the post stuck on "Thinking…".
    def parse_uri(url)
      URI.parse(url)
    rescue URI::InvalidURIError => e
      raise Error, "invalid term-llm URL (#{url.inspect}): #{e.message}"
    end

    def auth(request)
      key = SiteSetting.second_brain_term_llm_api_key
      request["Authorization"] = "Bearer #{key}" if key.present?
    end

    def build_http(uri, read_timeout: 120)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = read_timeout
      http
    end

    def post_json(path, body)
      uri = parse_uri("#{base_url}#{path}")
      http = build_http(uri, read_timeout: 120)

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      auth(request)
      request.body = body.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "term-llm returned HTTP #{response.code}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "invalid JSON from term-llm: #{e.message}"
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      raise Error, e.message
    end
  end
end
