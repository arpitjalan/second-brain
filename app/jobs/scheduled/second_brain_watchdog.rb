# frozen_string_literal: true

module ::Jobs
  # Backstop for chats stranded mid-turn by a hard worker kill (OOM, deploy
  # restart) — the case the in-line error handling can't reach, because no
  # exception was ever raised to surface. It finalizes such posts with a clear
  # note WITHOUT calling term-llm, so it can never re-poke a stuck run or amplify
  # a loop. Family volume is tiny, so a frequent sweep is cheap.
  class SecondBrainWatchdog < ::Jobs::Scheduled
    every 5.minutes

    # Floor for how long a turn must go untouched before it's treated as abandoned.
    STUCK_AFTER_SECONDS = 1800 # 30 minutes

    def execute(_args)
      return unless SiteSetting.second_brain_enabled

      bot_ids = ::SecondBrain::Agent.bot_user_ids
      return if bot_ids.blank?

      reconcile_stuck_placeholders(bot_ids, cutoff)
      reconcile_stuck_resumes(bot_ids, cutoff)
    end

    private

    # A live turn heartbeats its updated_at on every SSE frame (BotResponder
    # ALIVE_INTERVAL); the largest gap between heartbeats is one fully-silent tool
    # window — bounded by second_brain_stream_idle_timeout, which is operator-tunable
    # up to 3600s. Reconcile only well past that so a live-but-quiet turn is never
    # cut. So a row is "abandoned" once it's untouched for max(30m, ~2x the idle
    # window), by which point a live turn would have heartbeated.
    def cutoff
      idle = SiteSetting.second_brain_stream_idle_timeout.to_i
      idle = 600 if idle <= 0
      [STUCK_AFTER_SECONDS, (idle * 2) + 300].max.seconds.ago
    end

    # Bot posts still showing the live "Thinking…" placeholder long after any real
    # turn would have finished or errored.
    def reconcile_stuck_placeholders(bot_ids, cutoff)
      thinking = I18n.t("second_brain.thinking")
      Post
        .where(user_id: bot_ids, raw: thinking)
        .where("posts.updated_at < ?", cutoff)
        .find_each { |post| reconcile(post) }
    end

    # A run answered but whose continuation never finalized leaves the server-only
    # state field behind. PENDING (unanswered) questions are deliberately left
    # alone — they legitimately wait for the member, possibly for days.
    def reconcile_stuck_resumes(bot_ids, cutoff)
      post_ids = PostCustomField.where(name: ::SecondBrain::BotResponder::STATE_FIELD).pluck(:post_id)
      return if post_ids.empty?

      Post
        .where(id: post_ids, user_id: bot_ids)
        .where("posts.updated_at < ?", cutoff)
        .find_each do |post|
          state = parse(post, ::SecondBrain::BotResponder::ASK_FIELD)
          next unless state && state["status"] == "answered"
          reconcile(post)
        end
    end

    def reconcile(post)
      Rails.logger.warn(
        "second-brain: watchdog reconciling stranded post #{post.id} (topic #{post.topic_id})",
      )
      ::SecondBrain::BotResponder.new(post).reconcile_stranded!
    end

    def parse(post, field)
      raw = post.custom_fields[field]
      raw.present? ? JSON.parse(raw) : nil
    rescue JSON::ParserError
      nil
    end
  end
end
