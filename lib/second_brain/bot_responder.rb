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

    # Post custom fields holding the interactive ask_user state. ASK_FIELD is
    # client-exposed (questions/status/summary); STATE_FIELD is server-only
    # (session_id/response_id/sequence/pre-prompt text) and never serialized.
    ASK_FIELD = "second_brain_askuser"
    STATE_FIELD = "second_brain_askuser_state"

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

      # Show a breathing, self-narrating indicator until the answer starts.
      publish_cooked(placeholder, thinking_html(nil), done: false)

      # A stable session id per chat lets a later request answer/resume an
      # ask_user prompt (term-llm keys paused runs by session id).
      session_id = "sb_#{@topic.id}"
      result =
        begin
          stream_and_paint(placeholder, "", []) do |on_update|
            TermLlmClient.new.stream_respond(messages, session_id: session_id, &on_update)
          end
        rescue TermLlmClient::Error => e
          Rails.logger.warn("second-brain: reply failed: #{e.message}")
          { text: I18n.t("second_brain.errors.reply_failed"), tools: [], ask_user: nil }
        end

      conclude(placeholder, session_id, "", [], result, messages)
    end

    # Resume a chat that paused on an ask_user prompt, after the human answered
    # (enqueued by the answer controller). Streams the run's continuation — the
    # events after the prompt — into the same bot post.
    def resume!
      return unless @topic&.private_message?

      public_state = parse_json(@post.custom_fields[ASK_FIELD])
      server_state = parse_json(@post.custom_fields[STATE_FIELD])
      return if public_state.nil? || server_state.nil?
      return unless public_state["status"] == "answered"

      response_id = server_state["response_id"].to_s
      return if response_id.blank?

      session_id = server_state["session_id"]
      pre_text = server_state["pre_text"].to_s
      after = server_state["last_seq"].to_i

      publish_cooked(@post, thinking_html(nil), done: false)
      result =
        begin
          stream_and_paint(@post, pre_text, []) do |on_update|
            TermLlmClient.new.stream_events(response_id: response_id, after: after, &on_update)
          end
        rescue TermLlmClient::Error => e
          Rails.logger.warn("second-brain: resume failed: #{e.message}")
          { text: "", tools: [], ask_user: nil }
        end

      full_text = pre_text + result[:text].to_s
      tools = result[:tools] || []

      if result[:ask_user]
        # The continuation asked another question — pause again.
        pause_for_ask_user(@post, session_id, result, full_text, tools)
        return
      end

      finalize(@post, full_text, tools)
      public_state["status"] = "done"
      @post.custom_fields[ASK_FIELD] = public_state.to_json
      @post.save_custom_fields(true)
      maybe_title!(build_messages)
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Stream a term-llm call into `post`, painting the (optionally seeded) reply
    # as it accumulates. `seed_text`/`seed_tools` prefix a resumed continuation
    # with the text/tools produced before the ask_user pause. Yields an on_update
    # proc to the block, which invokes the actual streaming client method.
    def stream_and_paint(post, seed_text, seed_tools)
      last_update = monotonic
      last_tool_sig = nil
      on_update =
        proc do |text, tools|
          full_text = seed_text.to_s + text.to_s
          all_tools = seed_tools + tools
          now = monotonic
          tool_sig = all_tools.map { |t| [t[:name], t[:done]] }
          if tool_sig != last_tool_sig || now - last_update >= STREAM_THROTTLE
            if full_text.strip.present?
              markdown = render_reply(full_text, all_tools)
              publish_stream(post, markdown, done: false) if markdown.present?
            else
              # No answer text yet — name what stan is doing right now.
              publish_cooked(post, thinking_html(active_label(all_tools)), done: false)
            end
            last_update = now
            last_tool_sig = tool_sig
          end
        end
      yield on_update
    end

    # Either pause for an ask_user prompt or finalize the reply + title the chat.
    def conclude(post, session_id, seed_text, seed_tools, result, messages)
      full_text = seed_text.to_s + result[:text].to_s
      tools = seed_tools + (result[:tools] || [])
      if result[:ask_user]
        pause_for_ask_user(post, session_id, result, full_text, tools)
      else
        finalize(post, full_text, tools)
        maybe_title!(messages)
      end
    end

    # Persist the question set + run state on the post and refresh clients once so
    # the interactive form renders (client-side, from the serialized ASK_FIELD).
    def pause_for_ask_user(post, session_id, result, pre_text, pre_tools)
      au = result[:ask_user] || {}
      public_state = {
        "call_id" => au[:call_id],
        "status" => "pending",
        "questions" => au[:questions] || [],
      }
      server_state = {
        "session_id" => session_id,
        "response_id" => result[:response_id],
        "last_seq" => result[:last_seq],
        "pre_text" => pre_text,
      }

      body = render_reply(pre_text, pre_tools)
      body = I18n.t("second_brain.askuser.waiting") if body.blank?
      post.update_columns(raw: body)
      post.rebake!
      post.custom_fields[ASK_FIELD] = public_state.to_json
      post.custom_fields[STATE_FIELD] = server_state.to_json
      post.save_custom_fields(true)

      # Live viewers: push the question set so the client renders the form now
      # (the :revised refetch alone doesn't change cooked, so it wouldn't
      # re-trigger the decorator). Reload/late-join is covered by the serialized
      # field + the post decorator.
      publish_stream(post, body, done: true)
      publish_askuser(post, public_state)
      post.publish_change_to_clients!(:revised)
    end

    def publish_askuser(post, public_state)
      MessageBus.publish(
        "/second-brain/askuser",
        { post_id: post.id, askuser: public_state },
        user_ids: stream_user_ids,
      )
    rescue => e
      Rails.logger.warn("second-brain: askuser publish failed: #{e.message}")
    end

    # Persist the final answer once and tell clients streaming is done.
    def finalize(post, text, tools)
      final = render_reply(text, tools)
      final = I18n.t("second_brain.empty_reply") if final.blank?
      post.update_columns(raw: final)
      post.rebake!
      publish_stream(post, final, done: true)
      post.publish_change_to_clients!(:revised)
    end

    def parse_json(raw)
      return nil if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
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

    # Mirror term-llm's web UI tool icons so the chat looks consistent.
    def tool_icon(name)
      case name.to_s
      when "shell", "bash"
        "💻"
      when "read_file"
        "📄"
      when "write_file", "edit_file"
        "✏️"
      when "web_search"
        "🔍"
      when "read_url"
        "🌐"
      when "image_generate"
        "🎨"
      when "spawn_agent"
        "🤖"
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

    # Publish a partial/final chunk to the chat's participants only (scoped via
    # user_ids), on a dedicated channel the client paints from. `publish_stream`
    # takes markdown (cooked here); `publish_cooked` takes ready HTML (used for
    # the transient thinking indicator, built directly so its markup survives).
    def publish_stream(post, raw, done:)
      publish_cooked(post, PrettyText.cook(raw), done: done)
    end

    def publish_cooked(post, html, done:)
      MessageBus.publish(
        "/second-brain/stream",
        { post_id: post.id, html: html, done: done },
        user_ids: stream_user_ids,
      )
    rescue => e
      Rails.logger.warn("second-brain: stream publish failed: #{e.message}")
    end

    # Friendly present-tense verbs for the live "what stan is doing" indicator.
    TOOL_VERBS = {
      "web_search" => "Searching the web",
      "read_url" => "Reading a page",
      "read_file" => "Reading",
      "write_file" => "Writing",
      "edit_file" => "Editing",
      "shell" => "Running a command",
      "bash" => "Running a command",
      "image_generate" => "Creating an image",
      "spawn_agent" => "Thinking it through",
    }.freeze

    # Label for the breathing indicator: name the running tool, else "Thinking".
    def active_label(tools)
      running = tools.reverse.find { |t| !t[:done] }
      return "Thinking" if running.nil?
      TOOL_VERBS[running[:name].to_s] || "Working"
    end

    # A small animated "stan is working" pill, built as HTML (not markdown) so the
    # dots + label survive on the client. Transient — never persisted.
    def thinking_html(label)
      text = label.presence || "Thinking"
      dots =
        "<span class=\"sb-thinking__dots\">" \
          "<span></span><span></span><span></span></span>"
      "<div class=\"sb-thinking\">#{dots}" \
        "<span class=\"sb-thinking__label\">#{ERB::Util.html_escape(text)}</span></div>"
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

      transcript =
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

      forum_context.concat(transcript)
    end

    # Tell the bot it's in a forum chat and who it's talking to, so it can act on
    # the forum via its `discourse` skill. Off until the skill is deployed.
    def forum_context
      return [] unless SiteSetting.second_brain_forum_actions_enabled

      member = @topic.user&.username || "a family member"
      content = <<~MSG.strip
        You are an AI assistant inside a private Discourse forum that a family uses as a shared knowledge base and AI workspace. You are currently in a private chat with the forum member "#{member}".

        You can take actions on the forum — create topics, reply, search, send messages — using your "discourse" skill (it has the forum's API access configured). You always act as yourself (your own bot account); never impersonate members. Whenever you create or reference forum content, include the link.
      MSG

      [{ role: "system", content: content }]
    end
  end
end
