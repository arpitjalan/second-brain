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

    def self.configured?
      SiteSetting.second_brain_term_llm_url.present?
    end

    # Agentic, non-streaming reply via /v1/responses with server tools enabled,
    # so term-llm can web-search (and use its other tools) before answering.
    # `messages` is an array of { role:, content: } hashes (the conversation).
    # This is what the chat bot uses. (Streaming builds on this later.)
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

    # Simpler non-agentic completion via /v1/chat/completions (no server tools).
    # Kept for the legacy homepage proxy on `main`.
    def complete(messages)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      body = { messages: messages, stream: false }
      model = SiteSetting.second_brain_term_llm_model
      body[:model] = model if model.present?

      response = post_json("/v1/chat/completions", body)
      response.dig("choices", 0, "message", "content").to_s
    end

    private

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

    def post_json(path, body)
      uri = URI.parse("#{base_url}#{path}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      key = SiteSetting.second_brain_term_llm_api_key
      request["Authorization"] = "Bearer #{key}" if key.present?
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
