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

    # Non-streaming ask via /v1/chat/completions. Streaming and the richer
    # /v1/responses agentic path (web search, widgets) build on this.
    def ask(question)
      raise NotConfigured if SiteSetting.second_brain_term_llm_url.blank?

      body = { messages: [{ role: "user", content: question }], stream: false }
      model = SiteSetting.second_brain_term_llm_model
      body[:model] = model if model.present?

      response = post_json("/v1/chat/completions", body)
      response.dig("choices", 0, "message", "content").to_s
    end

    private

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
