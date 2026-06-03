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
      return if Agent.bot_user_ids.include?(post.user_id) # never reply to an agent's own post

      agent = Agent.for_topic(topic)
      return if agent.nil? # not a chat with any agent
      return unless agent.configured? # this agent's term-llm endpoint isn't set
      # A personal agent only serves its owner (defense-in-depth — create already
      # restricts who can open the PM).
      return if !agent.shared? && agent.owner_user_id != post.user_id

      Jobs.enqueue(:second_brain_reply, post_id: post.id)
    end

    # Find-or-create stan's "Thinking…" placeholder in a chat. Called from the
    # create controller (so the chat is alive the instant the member lands) AND
    # from the reply job. The lock makes the find-or-create atomic across the
    # request/job boundary — without it, the job's SELECT can run before the
    # controller's INSERT commits, so both create one and the chat ends up with
    # a second, orphaned "Thinking…" post that never resolves.
    def self.ensure_placeholder(topic, agent = Agent.for_topic(topic))
      thinking = I18n.t("second_brain.thinking")
      bot = agent&.user || Bot.user
      DistributedMutex.synchronize("second-brain-placeholder-#{topic.id}") do
        topic
          .posts
          .where(user_id: bot.id, raw: thinking)
          .order(post_number: :desc)
          .first ||
          PostCreator.create!(bot, topic_id: topic.id, raw: thinking, skip_validations: true)
      end
    end

    def initialize(post)
      @post = post
      @topic = post.topic
      @agent = Agent.for_topic(@topic) || Agent.family
      # Set once the turn reaches a terminal state (a finalized answer or a
      # paused question). Guards abort_with_failure! from clobbering a resolved
      # post if an unexpected error fires afterwards.
      @finalized = false
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
      # A plugin's :post_created handler can be registered more than once (it
      # accumulates across dev code-reloads), firing maybe_respond — and so this
      # job — several times for one message. Claim the turn on the triggering
      # post so exactly one job replies; the rest no-op instead of each calling
      # term-llm and streaming a duplicate answer.
      return unless claim_turn!

      # If a previous turn left a question pending (unanswered), the member sending
      # a new message means "move on": cancel that blocked run on term-llm and mark
      # it skipped so its form clears.
      superseded = supersede_pending_question!

      messages = build_messages
      return if messages.empty?

      # Reuse the placeholder the create controller already spawned (or make one
      # if this is a follow-up turn) and stream term-llm's answer into it.
      placeholder = self.class.ensure_placeholder(@topic, @agent)

      # Show a breathing, self-narrating indicator until the answer starts.
      publish_cooked(placeholder, thinking_html(nil), done: false)

      # A stable session id per chat lets a later request answer/resume an ask_user
      # prompt (term-llm keys paused runs by session id). But right after superseding
      # a pending question the cancelled run is still wrapping up on that session, and
      # term-llm rejects a concurrent run as "session busy" (streaming a conflict_error
      # that would surface as an empty reply). Use a per-turn session id in that case
      # so this turn runs cleanly on its own session — answer/resume within it works.
      session_id = superseded ? "sb_#{@topic.id}_#{@post.id}" : "sb_#{@topic.id}"
      result =
        begin
          stream_and_paint(placeholder, "", []) do |on_update|
            @agent.client.stream_respond(messages, session_id: session_id, &on_update)
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

      # Sidekiq is at-least-once: claim this resume so a re-delivered or
      # concurrent duplicate job can't double-stream and double-finalize into the
      # same post. (The status flip to "done"/"interrupted" below already blocks a
      # *later* duplicate; this closes the concurrent window before that happens.)
      return unless claim_resume!(public_state["call_id"])

      response_id = server_state["response_id"].to_s
      return if response_id.blank?

      session_id = server_state["session_id"]
      pre_text = server_state["pre_text"].to_s
      after = server_state["last_seq"].to_i
      # JSON.parse gives string keys; the render code reads tool hashes by symbol
      # (t[:name], t[:done], …), so restore symbol keys for the seeded tools.
      pre_tools = Array(server_state["pre_tools"]).map { |t| t.transform_keys(&:to_sym) }

      publish_cooked(@post, thinking_html(nil), done: false)
      error = nil
      result =
        begin
          stream_and_paint(@post, pre_text, pre_tools) do |on_update|
            @agent.client.stream_events(response_id: response_id, after: after, &on_update)
          end
        rescue TermLlmClient::Error => e
          Rails.logger.warn("second-brain: resume failed: #{e.class}: #{e.message}")
          error = e
          { text: "", tools: [], ask_user: nil }
        end

      full_text = pre_text + result[:text].to_s
      tools = pre_tools + (result[:tools] || [])

      if result[:ask_user]
        # The continuation asked another question — pause again.
        pause_for_ask_user(@post, session_id, result, full_text, tools)
        return
      end

      # Never strand the post silently: if the continuation failed, finalize with
      # whatever streamed plus a clear note so the user knows to re-ask.
      if error
        note = I18n.t("second_brain.askuser.interrupted")
        body = full_text.strip.present? ? "#{full_text}\n\n#{note}" : note
        finalize(@post, body, tools)
        public_state["status"] = "interrupted"
      else
        finalize(@post, full_text, tools)
        public_state["status"] = "done"
      end
      @post.custom_fields[ASK_FIELD] = public_state.to_json
      # The run is finished — drop the server-only state so it doesn't linger
      # (and can't confuse a stray future resume).
      @post.custom_fields.delete(STATE_FIELD)
      @post.save_custom_fields(true)
      maybe_title!(build_messages)
    end

    # Called by the reply job when respond!/resume! raised an *unexpected* error
    # (a TermLlmClient::Error is already handled inside them and resolves the
    # post). Ensures the member never sits on a "Thinking…" placeholder forever:
    # paint the generic failure message onto the post being worked — unless we
    # already reached a terminal state (a finalized answer or a paused question),
    # which we must not clobber. Best-effort and self-guarded so it can't re-raise
    # back into the job.
    def abort_with_failure!(resume:)
      return if @finalized

      # respond! paints the not-yet-resolved "Thinking…" placeholder; resume!
      # works the bot post itself.
      post = resume ? @post : self.class.ensure_placeholder(@topic, @agent)
      return if post.nil?
      finalize(post, I18n.t("second_brain.errors.reply_failed"), [])
    rescue => e
      Rails.logger.warn("second-brain: failed to surface reply error: #{e.class}: #{e.message}")
    end

    # Called by the watchdog for a turn stranded mid-flight by a hard worker kill
    # (OOM, deploy restart) before any terminal state — the case the in-line error
    # handling can't reach because no exception was raised. Finalizes the post with
    # a clear note WITHOUT calling term-llm, so it can NEVER re-poke a stuck run or
    # amplify a loop. Preserves any partial content already shown; closes out a
    # stranded resume's lingering state. Best-effort and self-guarded.
    def reconcile_stranded!
      thinking = I18n.t("second_brain.thinking").strip
      note = I18n.t("second_brain.askuser.interrupted")
      current = @post.raw.to_s.strip
      body = current.blank? || current == thinking ? note : "#{@post.raw.rstrip}\n\n#{note}"
      finalize(@post, body, [])

      # If a resume was stranded (answered but never finalized), close it so it
      # can't be retried into the same dead run.
      public_state = parse_json(@post.custom_fields[ASK_FIELD])
      if public_state
        public_state["status"] = "interrupted"
        @post.custom_fields[ASK_FIELD] = public_state.to_json
        @post.custom_fields.delete(STATE_FIELD)
        @post.save_custom_fields(true)
      end
      true
    rescue => e
      Rails.logger.warn("second-brain: watchdog reconcile failed (post #{@post&.id}): #{e.class}: #{e.message}")
      false
    end

    private

    # Atomically mark the triggering post as replied-to. Returns true for the
    # first caller, false for any duplicate job for the same post. We hit
    # PostCustomField directly (not @post.custom_fields, which a sibling job may
    # have cached as empty) so the check sees a concurrent claim immediately.
    #
    # The claim is taken up-front (before term-llm), so it's intentionally
    # non-recoverable: if this job is hard-killed before painting anything, the
    # turn stays claimed and the message goes unanswered. That's the same
    # no-retry outcome as before (the job swallows errors and Sidekiq doesn't
    # retry); a TermLlmClient::Error still resolves the placeholder with the
    # reply_failed message, so only a process kill in the gap before any output
    # loses the turn — a negligible window we accept to kill the duplicate-reply.
    def claim_turn!
      DistributedMutex.synchronize("second-brain-reply-#{@post.id}") do
        next false if PostCustomField.exists?(post_id: @post.id, name: "second_brain_replied")
        PostCustomField.create!(post_id: @post.id, name: "second_brain_replied", value: "t")
        true
      end
    end

    # Like claim_turn!, but for a resume. Keyed on the bot post + the *answered*
    # call_id (not just the post) so a genuine next ask_user round — same post,
    # new call_id — can still resume, while a duplicate job for the same answer
    # no-ops. A blank call_id (shouldn't happen) collapses to a single claim.
    def claim_resume!(call_id)
      field = "second_brain_resumed_#{call_id}"
      DistributedMutex.synchronize("second-brain-resume-#{@post.id}-#{call_id}") do
        next false if PostCustomField.exists?(post_id: @post.id, name: field)
        PostCustomField.create!(post_id: @post.id, name: field, value: "t")
        true
      end
    end

    # A new message supersedes any still-pending ask_user question on this chat:
    # cancel the blocked run on term-llm (best-effort) and mark the old question
    # skipped so its form clears. Returns true if it superseded one (so the caller
    # runs this turn on a fresh session, away from the still-finishing old run).
    # Self-guarded — never breaks the new turn.
    def supersede_pending_question!
      pending =
        @topic
          .posts
          .where(user_id: @agent.bot_user_id)
          .where("posts.post_number < ?", @post.post_number)
          .order(post_number: :desc)
          .detect { |p| (parse_json(p.custom_fields[ASK_FIELD]) || {})["status"] == "pending" }
      return false if pending.nil?

      public_state = parse_json(pending.custom_fields[ASK_FIELD]) || {}
      server_state = parse_json(pending.custom_fields[STATE_FIELD]) || {}

      sid = server_state["session_id"]
      cid = public_state["call_id"]
      if sid.present? && cid.present?
        begin
          @agent.client.submit_ask_user(session_id: sid, call_id: cid, cancelled: true)
        rescue TermLlmClient::Error => e
          # Already gone/expired, or term-llm down — the run will time out anyway.
          Rails.logger.warn("second-brain: superseding ask_user (post #{pending.id}): #{e.class}: #{e.message}")
        end
      end

      public_state["status"] = "skipped"
      public_state["skipped"] = true
      pending.custom_fields[ASK_FIELD] = public_state.to_json
      pending.custom_fields.delete(STATE_FIELD)
      pending.save_custom_fields(true)
      publish_askuser(pending, public_state)
      pending.publish_change_to_clients!(:revised)
      true
    rescue => e
      Rails.logger.warn("second-brain: supersede_pending_question! failed: #{e.class}: #{e.message}")
      false
    end

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
              # No answer text yet — stream the tool calls as they run, with the
              # live "working" pill beneath them.
              publish_cooked(post, streaming_html(all_tools), done: false)
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

      # A paused question is a terminal state for this turn — the abort path must
      # not later overwrite it with a failure message (this also covers the
      # duplicate-question early return below, which keeps an existing question).
      @finalized = true

      # Don't clobber a question that's already awaiting the user with a different
      # one — that would make the first unanswerable. (Defensive; rare.)
      existing = parse_json(post.custom_fields[ASK_FIELD])
      if existing && existing["status"] == "pending" && existing["call_id"] != au[:call_id]
        Rails.logger.warn("second-brain: skipping duplicate ask_user pause on post #{post.id}")
        return
      end

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
        # Carry the tools that ran before the pause so the resumed continuation
        # re-renders them above its answer (read back with symbol keys in resume!).
        "pre_tools" => pre_tools,
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
      @finalized = true
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
    # to our same-origin proxy path, which forwards to term-llm with the token.
    # Family uses the legacy "/second-brain/widgets/…"; a personal agent uses an
    # agent-scoped path so the widget's own relative fetches stay on that agent.
    def proxy_widget_links(markdown)
      base_url = @agent.url.to_s.sub(%r{/+\z}, "")
      return markdown if base_url.blank?

      prefix =
        if @agent.shared?
          "/second-brain/widgets/"
        else
          "/second-brain/agent-widgets/#{@agent.user.username}/"
        end
      path = (URI.parse(base_url).path.presence rescue nil).to_s
      result = markdown.gsub("#{base_url}/widgets/", prefix)
      result.gsub(%r{(?<![\w:/])#{Regexp.escape("#{path}/widgets/")}}, prefix)
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
        fence = "`" * [(body.scan(/`+/).map(&:length).max || 0) + 1, 3].max
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

    # Label for the breathing indicator: name the running tool, else nil so the
    # pill shows (and cycles) a generic "thinking" word.
    def active_label(tools)
      running = tools.reverse.find { |t| !t[:done] }
      return nil if running.nil?
      TOOL_VERBS[running[:name].to_s] || "Working"
    end

    # Playful synonyms for the generic "thinking" state (no tool running yet). We
    # pick one at random per render so even a quick turn varies, and the client
    # (second-brain-thinking.js) rotates among them every 10s on longer turns.
    THINKING_WORDS = [
      "Thinking",
      "Pondering",
      "Mulling it over",
      "Noodling on it",
      "Working it out",
      "Connecting the dots",
      "Percolating",
      "Ruminating",
      "Untangling this",
      "Putting it together",
    ].freeze

    # A small animated "stan is working" pill, built as HTML (not markdown) so the
    # dots + label survive on the client. Transient — never persisted. With no tool
    # label it shows a random "thinking" word and is marked .sb-thinking--cycle (+
    # the word list in data-sb-words) so the client rotates it.
    def thinking_html(label)
      cycle = label.blank?
      text = label.presence || THINKING_WORDS.sample
      classes = cycle ? "sb-thinking sb-thinking--cycle" : "sb-thinking"
      data =
        if cycle
          " data-sb-words=\"#{ERB::Util.html_escape(THINKING_WORDS.join("|"))}\""
        else
          ""
        end
      dots =
        "<span class=\"sb-thinking__dots\">" \
          "<span></span><span></span><span></span></span>"
      "<div class=\"#{classes}\"#{data}>#{dots}" \
        "<span class=\"sb-thinking__label\">#{ERB::Util.html_escape(text)}</span></div>"
    end

    # The live view before any answer text: the tool calls as they run (collapsed
    # by default — calmer; the user can expand and the morph keeps that choice via
    # MORPH_OPTIONS), with the "working" pill beneath.
    def streaming_html(tools)
      pill = thinking_html(active_label(tools))
      return pill if tools.blank?
      "#{PrettyText.cook(tool_summary(tools))}#{pill}"
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

      title = @agent.client.complete(prompt).to_s.strip.delete('"').tr("\n", " ").strip
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
      bot_id = @agent.bot_user_id
      thinking = I18n.t("second_brain.thinking")

      transcript =
        @topic
          .posts
          .where(post_type: Post.types[:regular])
          .order(:post_number)
          .pluck(:user_id, :raw)
          .filter_map do |user_id, raw|
            content = raw.to_s.strip
            next if content.blank?
            next if content == thinking # live placeholder

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
