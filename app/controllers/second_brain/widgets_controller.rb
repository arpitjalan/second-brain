# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"

module ::SecondBrain
  # Reverse-proxies term-llm widget pages (and their assets/JSON) through
  # Discourse, injecting the Bearer token server-side. The browser loads
  # /second-brain/widgets/<name>/… (family agent) or
  # /second-brain/agent-widgets/<agent>/<name>/… (a personal agent) — same origin,
  # authenticated by the Discourse session; we fetch <term-llm>/widgets/<name>/…
  # with that agent's token. This keeps the token out of the browser, and a
  # personal agent's widgets private to their owner.
  class WidgetsController < ::ApplicationController
    requires_plugin "second-brain"
    requires_login
    skip_before_action :check_xhr, only: %i[show], raise: false
    # Widget writes (POST/PUT/…) are authenticated upstream by the agent's Bearer
    # token, not Discourse's CSRF token — skip the forgery check for the proxy.
    skip_before_action :verify_authenticity_token, only: %i[show], raise: false

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

    # The sidebar's widget list: aggregate widgets across the agents this member
    # can access (the family agent + their own), each tagged with its agent +
    # same-origin proxy url.
    def index
      widgets = Agent.available_to(current_user).flat_map { |agent| agent_widgets(agent) }
      render json: { widgets: widgets }
    end

    def show
      agent = widget_agent
      base_url = agent.url.to_s.sub(%r{/+\z}, "")
      raise Discourse::NotFound if base_url.blank?

      path = params[:path].to_s
      raise Discourse::InvalidParameters, :path if path.include?("..")

      # Don't let dev mini-profiler inject its badge/script into the widget HTML.
      Rack::MiniProfiler.deauthorize_request if defined?(Rack::MiniProfiler)

      target = +"#{base_url}/widgets/#{path}"
      target << "?#{request.query_string}" if request.query_string.present?

      upstream, final_uri =
        fetch_following_redirects(
          URI.parse(target),
          agent,
          method: request.request_method.downcase.to_sym,
          body: request.raw_post.presence,
          content_type: request.media_type,
        )

      content_type = upstream["content-type"].presence || "application/octet-stream"
      body = upstream.body.to_s
      if content_type.include?("html")
        body = rewrite_widget_base(body, agent)
        # A widget's data calls are RELATIVE (`fetch('api/jobs')`), which only
        # resolve right when the page's base ends in "/". Rather than redirect to a
        # trailing slash (impossible to do safely — a glob route hides the slash from
        # request.path, so the redirect loops), inject a <base href> pointing at the
        # widget's own directory. Relative refs then resolve correctly with OR without
        # a trailing slash on the URL, and no redirect happens.
        body = inject_base_href(body, widget_base_href(agent, final_uri))
      end
      response.headers["Cache-Control"] = "no-store"
      response.headers["Content-Security-Policy"] = WIDGET_CSP
      render body: body, status: upstream.code.to_i, content_type: content_type
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
      render plain: "Could not reach the widget: #{e.message}", status: :bad_gateway
    end

    private

    # Which agent's widgets this request is for. The agent-scoped route carries an
    # <agent> segment (access-checked); the legacy route (no segment) = family.
    def widget_agent
      requested = params[:agent].to_s.strip
      return Agent.family if requested.blank?

      agent = Agent.resolve(::User.find_by(username_lower: requested.downcase))
      raise Discourse::NotFound if agent.nil?
      raise Discourse::InvalidAccess unless agent.shared? || agent.owner_user_id == current_user.id
      agent
    end

    # Same-origin proxy prefix for an agent's widgets. Family keeps the legacy path
    # (so old embeds keep working); personal agents get an agent-scoped path so the
    # widget's own relative fetches inherit the agent.
    def widget_proxy_prefix(agent)
      agent.shared? ? "/second-brain/widgets/" : "/second-brain/agent-widgets/#{agent.user.username}/"
    end

    # The same-origin URL the widget's relative refs should resolve against: the
    # proxy equivalent of the directory term-llm actually served (final_uri after
    # following its trailing-slash redirect). Preserves that trailing slash so
    # `fetch('api/x')` resolves into the widget.
    def widget_base_href(agent, final_uri)
      after = final_uri.path.to_s.split("/widgets/", 2)[1].to_s
      "#{widget_proxy_prefix(agent)}#{after}"
    end

    # Inject `<base href>` right after <head> so relative URLs resolve against the
    # widget's directory regardless of the page URL's trailing slash. Only when the
    # doc has a <head> and no <base> of its own (term-llm widgets don't set one).
    def inject_base_href(body, href)
      return body if href.blank? || body.match?(/<base\b/i) || !body.match?(/<head[^>]*>/i)
      body.sub(/<head[^>]*>/i) { |head| %(#{head}<base href="#{CGI.escapeHTML(href)}">) }
    end

    # Keep a widget page talking to ITS agent. term-llm widgets use relative paths
    # today (which already inherit the agent-scoped prefix), but a widget that
    # hardcodes an ABSOLUTE widget-base — the term-llm one (e.g. "/chat/widgets/…")
    # or the family proxy ("/second-brain/widgets/…") — would otherwise escape a
    # personal agent and hit the family proxy. Rewrite those back to this agent's
    # prefix. No-op on current widgets; only the main HTML document is rewritten
    # (JS-constructed URLs are out of scope — see docs/TODO.md, separate-origin work).
    def rewrite_widget_base(body, agent)
      prefix = widget_proxy_prefix(agent)
      termllm_widgets = "#{URI.parse(agent.url).path.to_s.sub(%r{/+\z}, "")}/widgets/"
      body = body.gsub(termllm_widgets, prefix) unless termllm_widgets == prefix
      body = body.gsub("/second-brain/widgets/", prefix) unless agent.shared?
      body
    end

    # The widgets for one agent, tagged with its identity + proxy urls.
    def agent_widgets(agent)
      return [] unless agent.user
      base_url = agent.url.to_s.sub(%r{/+\z}, "")
      return [] if base_url.blank?

      # Short timeouts: the status JSON is quick, and #index fans out across every
      # accessible agent on the request thread — one slow/down agent mustn't stall
      # the whole sidebar.
      upstream, =
        fetch_following_redirects(
          URI.parse("#{base_url}/admin/widgets/status"),
          agent,
          open_timeout: 4,
          read_timeout: 6,
        )
      data = JSON.parse(upstream.body) rescue {}
      prefix = widget_proxy_prefix(agent)
      Array(data["widgets"]).filter_map do |w|
        mount = (w["mount"] || w["id"]).to_s
        next if mount.blank?
        {
          mount: mount,
          title: w["title"].presence || mount,
          description: w["description"],
          state: w["state"],
          agent: agent.user.username,
          owned: !agent.shared?,
          url: "#{prefix}#{mount}/", # trailing slash: the widget's relative fetches (e.g. `api/jobs`) only resolve right when the page URL ends in `/`
        }
      end
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      []
    end

    # Widget routes often 3xx (trailing-slash / index normalization); follow the
    # redirects server-side, carrying the token on every hop, so the iframe gets
    # the final 200 — not a "Temporary Redirect" body. Redirects must stay on the
    # exact term-llm origin (an SSRF guard) — pin scheme+host+port, not just host,
    # so a redirect can't downgrade to http or hop to another port on the same host
    # and leak the Bearer token there.
    def fetch_following_redirects(
      uri,
      agent,
      method: :get,
      body: nil,
      content_type: nil,
      open_timeout: 10,
      read_timeout: 30
    )
      key = agent.token
      allowed_origin = [uri.scheme, uri.host, uri.port]
      verb = Net::HTTP.const_get(method.to_s.capitalize) # Get / Post / Put / Patch / Delete

      5.times do
        raise Discourse::InvalidAccess if [uri.scheme, uri.host, uri.port] != allowed_origin

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout

        request = verb.new(uri)
        request["Authorization"] = "Bearer #{key}" if key.present?
        if body.present?
          request.body = body
          request["Content-Type"] = content_type if content_type.present?
        end
        response = http.request(request)

        unless response.is_a?(Net::HTTPRedirection) && response["location"].present?
          return [response, uri]
        end

        uri = URI.join(uri.to_s, response["location"])
      end

      raise Discourse::InvalidParameters, :path # too many redirects
    end
  end
end
