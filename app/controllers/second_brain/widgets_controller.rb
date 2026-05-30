# frozen_string_literal: true

require "net/http"
require "uri"

module ::SecondBrain
  # Reverse-proxies term-llm widget pages (and their assets/JSON) through
  # Discourse, injecting the Bearer token server-side. The iframe loads
  # /second-brain/widgets/<name>/… (same origin, authenticated by the Discourse
  # session); we fetch <term-llm>/widgets/<name>/… with the token. This keeps
  # the term-llm token out of the browser and the widget private to the family.
  class WidgetsController < ::ApplicationController
    requires_login
    skip_before_action :check_xhr, only: %i[show], raise: false

    # Widgets are self-contained pages with inline scripts; Discourse's strict
    # CSP would block them. We set our own (permissive) CSP on the proxied
    # response — Discourse's CSP middleware skips responses that already carry a
    # Content-Security-Policy header.
    WIDGET_CSP = [
      "default-src 'self' data: blob:",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https: http:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "frame-ancestors 'self'",
    ].join("; ").freeze

    # Lists the family's term-llm widgets (for the sidebar). Pulls the JSON
    # status from term-llm and returns mount/title/state for each.
    def index
      base_url = SiteSetting.second_brain_term_llm_url.to_s.sub(%r{/+\z}, "")
      return render json: { widgets: [] } if base_url.blank?

      upstream = fetch_following_redirects(URI.parse("#{base_url}/admin/widgets/status"))
      data = (JSON.parse(upstream.body) rescue {})
      widgets =
        Array(data["widgets"]).map do |w|
          {
            mount: w["mount"] || w["id"],
            title: w["title"].presence || w["mount"] || w["id"],
            description: w["description"],
            state: w["state"],
          }
        end

      render json: { widgets: widgets.select { |w| w[:mount].present? } }
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      render json: { widgets: [] }
    end

    def show
      base_url = SiteSetting.second_brain_term_llm_url.to_s.sub(%r{/+\z}, "")
      raise Discourse::NotFound if base_url.blank?

      path = params[:path].to_s
      raise Discourse::InvalidParameters, :path if path.include?("..")

      # Don't let dev mini-profiler inject its badge/script into the widget HTML.
      Rack::MiniProfiler.deauthorize_request if defined?(Rack::MiniProfiler)

      target = +"#{base_url}/widgets/#{path}"
      target << "?#{request.query_string}" if request.query_string.present?

      upstream = fetch_following_redirects(URI.parse(target))

      content_type = upstream["content-type"].presence || "application/octet-stream"
      response.headers["Cache-Control"] = "no-store"
      response.headers["Content-Security-Policy"] = WIDGET_CSP
      render body: upstream.body, status: upstream.code.to_i, content_type: content_type
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      render plain: "Could not reach the widget: #{e.message}", status: :bad_gateway
    end

    private

    # Widget routes often 3xx (trailing-slash / index normalization); follow the
    # redirects server-side, carrying the token on every hop, so the iframe gets
    # the final 200 — not a "Temporary Redirect" body. Redirects must stay on the
    # term-llm host (an SSRF guard — never follow a redirect to another host).
    def fetch_following_redirects(uri)
      key = SiteSetting.second_brain_term_llm_api_key
      allowed_host = uri.host

      5.times do
        raise Discourse::InvalidAccess if uri.host != allowed_host

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{key}" if key.present?
        response = http.request(request)

        unless response.is_a?(Net::HTTPRedirection) && response["location"].present?
          return response
        end

        uri = URI.join(uri.to_s, response["location"])
      end

      raise Discourse::InvalidParameters, :path # too many redirects
    end
  end
end
