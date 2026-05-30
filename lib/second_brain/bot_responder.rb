# frozen_string_literal: true

module ::SecondBrain
  # Decides whether a newly-created post is a human message in a chat (a PM with
  # the bot) and, if so, has the bot reply with term-llm's answer.
  class BotResponder
    # Cheap synchronous guard called from the :post_created hook; the actual
    # term-llm call happens off the request in a job.
    def self.maybe_respond(post)
      return unless SiteSetting.second_brain_enabled
      return if post.blank? || post.post_type != Post.types[:regular]

      topic = post.topic
      return unless topic&.private_message?
      return unless TermLlmClient.configured?
      return if Bot.user?(post.user_id) # never reply to ourselves (loop guard)
      return unless topic.topic_allowed_users.exists?(user_id: Bot.user.id)

      Jobs.enqueue(:second_brain_reply, post_id: post.id)
    end

    def initialize(post)
      @post = post
      @topic = post.topic
    end

    # Minimum seconds between live post updates while streaming.
    STREAM_THROTTLE = 0.6

    def respond!
      return unless @topic&.private_message?

      messages = build_messages
      return if messages.empty?

      # Post a placeholder immediately so the user sees the bot is replying;
      # we then stream term-llm's answer into this same post.
      placeholder =
        PostCreator.create!(
          Bot.user,
          topic_id: @topic.id,
          raw: I18n.t("second_brain.thinking"),
          skip_validations: true,
        )

      final_text = +""
      final_tools = []
      last_update = monotonic
      last_tool_sig = nil

      begin
        result =
          TermLlmClient
            .new
            .stream_respond(messages) do |text, tools|
              now = monotonic
              tool_sig = tools.map { |t| [t[:name], t[:done]] }
              # Publish immediately when a tool starts/finishes; throttle text.
              if tool_sig != last_tool_sig || now - last_update >= STREAM_THROTTLE
                markdown = render_reply(text, tools)
                publish_stream(placeholder, markdown, done: false) if markdown.present?
                last_update = now
                last_tool_sig = tool_sig
              end
            end
        final_text = result[:text].to_s
        final_tools = result[:tools] || []
      rescue TermLlmClient::Error => e
        Rails.logger.warn("second-brain: reply failed: #{e.message}")
        final_text = I18n.t("second_brain.errors.reply_failed")
      end

      final = render_reply(final_text, final_tools)
      final = I18n.t("second_brain.empty_reply") if final.blank?

      # Persist the final answer once (no per-token revisions), then tell the
      # client streaming is done; a single :revised lets non-streaming viewers
      # (and other participants) pick up the final post normally.
      placeholder.update_columns(raw: final)
      placeholder.rebake!
      publish_stream(placeholder, final, done: true)
      placeholder.publish_change_to_clients!(:revised)

      maybe_title!(messages)
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Reply markdown: a collapsible tool-call summary (when tools ran) above the
    # answer, mirroring term-llm's own UI.
    def render_reply(text, tools)
      parts = []
      parts << tool_summary(tools) if tools.present?
      body = proxy_widget_links(text.to_s)
      parts << body if body.strip.present?
      parts.join("\n\n")
    end

    # term-llm widget links point at its own server and need its Bearer token.
    # Rewrite them (relative "/chat/widgets/…" or absolute "<host>/chat/widgets/…")
    # to our same-origin proxy path "/second-brain/widgets/…", which forwards to
    # term-llm with the token. The client then embeds that as an iframe.
    PROXY_WIDGETS = "/second-brain/widgets/"

    def proxy_widget_links(markdown)
      base_url = SiteSetting.second_brain_term_llm_url.to_s.sub(%r{/+\z}, "")
      return markdown if base_url.blank?

      path = (URI.parse(base_url).path.presence rescue nil).to_s
      result = markdown.gsub("#{base_url}/widgets/", PROXY_WIDGETS)
      result.gsub(%r{(?<![\w:/])#{Regexp.escape("#{path}/widgets/")}}, PROXY_WIDGETS)
    end

    def tool_summary(tools)
      title =
        if tools.all? { |t| t[:done] }
          "🔧 #{tools.size} tool call#{"s" if tools.size != 1}"
        else
          "🔧 working…"
        end

      blocks = tools.map { |t| tool_block(t) }
      "[details=\"#{title}\"]\n\n#{blocks.join("\n\n")}\n\n[/details]"
    end

    def tool_block(tool)
      mark = tool[:done] ? (tool[:success] == false ? "⚠️" : "✓") : "…"
      lines = ["**#{tool_icon(tool[:name])} #{tool[:name]}** #{mark}"]
      rendered = tool_args_markdown(tool)
      lines << rendered if rendered.present?
      lines.join("\n")
    end

    def tool_icon(name)
      case name.to_s
      when "shell"
        "💻"
      when "web_search"
        "🔍"
      else
        "🔧"
      end
    end

    # Non-essential tool args we hide (matching term-llm's chat UI), so the
    # summary stays clean — the meaningful arg (command/pattern/path/…) is enough.
    NOISE_ARG_KEYS = %w[
      description context_lines max_results multiline files_with_matches
      include exclude type start_line end_line case_sensitive head_limit
      offset limit count line_numbers timeout_seconds timeout
    ].freeze

    # Show the important args first.
    ARG_PRIORITY = %w[command query pattern name prompt url path].freeze

    # Render a tool's arguments as labeled lines. Short values go inline; long or
    # multi-line values go in a safely-fenced, truncated code block. This MUST
    # never break markdown — tool args can be whole scripts/heredocs.
    def tool_args_markdown(tool)
      args = tool[:args].is_a?(Hash) ? tool[:args] : {}
      pairs =
        args.reject do |k, v|
          NOISE_ARG_KEYS.include?(k.to_s) || v.nil? || v.to_s.strip.empty?
        end

      if pairs.empty?
        info = tool[:info].to_s.sub(/\A\(/, "").sub(/\)\z/, "").strip
        return info.present? ? "_#{info}_" : ""
      end

      pairs
        .sort_by { |k, _| [ARG_PRIORITY.index(k.to_s) || 99, k.to_s] }
        .map { |k, v| format_arg(k.to_s, v.to_s) }
        .join("\n")
    end

    def format_arg(key, value)
      value = value.strip

      if !value.include?("\n") && value.length <= 120
        "#{key}: `#{value.tr("`", "'")}`"
      else
        lines = value.lines
        truncated = lines.length > 30 || value.length > 2000
        body = lines.first(30).join
        body = body[0, 2000] if body.length > 2000
        body = body.rstrip
        body += "\n… (truncated)" if truncated
        fence = "`" * [((body.scan(/`+/).map(&:length).max) || 0) + 1, 3].max
        "#{key}:\n#{fence}\n#{body}\n#{fence}"
      end
    end

    # Publish a partial/final cooked chunk to the chat's participants only
    # (scoped via user_ids), on a dedicated channel the client paints from.
    def publish_stream(post, raw, done:)
      MessageBus.publish(
        "/second-brain/stream",
        { post_id: post.id, html: PrettyText.cook(raw), done: done },
        user_ids: stream_user_ids,
      )
    rescue => e
      Rails.logger.warn("second-brain: stream publish failed: #{e.message}")
    end

    def stream_user_ids
      @stream_user_ids ||= @topic.topic_allowed_users.pluck(:user_id)
    end

    # Auto-name the chat once, from the first user message (a quick, non-agentic
    # term-llm call). The chat starts with a throwaway title derived from the
    # message; this replaces it with something concise.
    def maybe_title!(messages)
      return if @topic.custom_fields["second_brain_titled"]

      first_user = messages.find { |m| m[:role] == "user" }
      return if first_user.nil?

      prompt = [
        {
          role: "system",
          content:
            "Generate a concise chat title of 3-6 words summarizing the user's " \
              "message. Reply with only the title — no quotes, no trailing punctuation.",
        },
        { role: "user", content: first_user[:content].to_s.truncate(500) },
      ]

      title = TermLlmClient.new.complete(prompt).to_s.strip.delete('"').tr("\n", " ").strip
      title = title.truncate(80)
      return if title.length < 2

      @topic.update!(title: title)
      @topic.custom_fields["second_brain_titled"] = true
      @topic.save_custom_fields
    rescue => e
      Rails.logger.warn("second-brain: title generation failed: #{e.message}")
    end

    # The whole PM transcript, mapped to term-llm chat roles.
    def build_messages
      bot_id = Bot.user.id
      @topic
        .posts
        .where(post_type: Post.types[:regular])
        .order(:post_number)
        .pluck(:user_id, :raw)
        .filter_map do |user_id, raw|
          content = raw.to_s.strip
          next if content.blank?

          { role: user_id == bot_id ? "assistant" : "user", content: content }
        end
    end
  end
end
