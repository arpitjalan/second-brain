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

    def show
      base_url = SiteSetting.second_brain_term_llm_url.to_s.sub(%r{/+\z}, "")
      raise Discourse::NotFound if base_url.blank?

      path = params[:path].to_s
      raise Discourse::InvalidParameters, :path if path.include?("..")

      target = +"#{base_url}/widgets/#{path}"
      target << "?#{request.query_string}" if request.query_string.present?

      uri = URI.parse(target)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      proxied = Net::HTTP::Get.new(uri)
      key = SiteSetting.second_brain_term_llm_api_key
      proxied["Authorization"] = "Bearer #{key}" if key.present?
      upstream = http.request(proxied)

      content_type = upstream["content-type"].presence || "application/octet-stream"
      response.headers["Cache-Control"] = "no-store"
      render body: upstream.body, status: upstream.code.to_i, content_type: content_type
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      render plain: "Could not reach the widget: #{e.message}", status: :bad_gateway
    end
  end
end
