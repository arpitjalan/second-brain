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

      final = +""
      last_update = monotonic

      begin
        final =
          TermLlmClient
            .new
            .stream_respond(messages) do |accumulated|
              now = monotonic
              if now - last_update >= STREAM_THROTTLE && accumulated.strip.present?
                # Live paint only — no DB write, no refetch. The client paints
                # this HTML into the post's .cooked element.
                publish_stream(placeholder, accumulated, done: false)
                last_update = now
              end
            end
            .to_s
      rescue TermLlmClient::Error => e
        Rails.logger.warn("second-brain: reply failed: #{e.message}")
        final = I18n.t("second_brain.errors.reply_failed")
      end

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
