# frozen_string_literal: true

module ::Jobs
  # Calls term-llm for a chat (PM) and posts the bot's reply, off the request.
  # Never re-raises, so a failed reply can't trigger a Sidekiq retry storm
  # (e.g. if the topic was deleted between enqueue and run).
  class SecondBrainReply < ::Jobs::Base
    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return if post.blank?

      resume = args[:mode].to_s == "resume"
      responder = ::SecondBrain::BotResponder.new(post)
      begin
        resume ? responder.resume! : responder.respond!
      rescue => e
        # A handled TermLlmClient::Error already resolves the post inside
        # respond!/resume!; only *unexpected* errors reach here. Don't leave the
        # member staring at a "Thinking…" placeholder forever — surface a friendly
        # failure on the post, and log with a distinct, greppable tag. We still
        # don't re-raise, so a deterministic bug won't retry-storm.
        Rails.logger.warn(
          "second-brain: reply job crashed (#{resume ? "resume" : "respond"}): " \
            "#{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}",
        )
        responder.abort_with_failure!(resume: resume)
      end
    end
  end
end
