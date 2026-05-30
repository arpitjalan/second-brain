# frozen_string_literal: true

module ::Jobs
  # Calls term-llm for a chat (PM) and posts the bot's reply, off the request.
  # Swallows errors so a failed reply never triggers a Sidekiq retry storm
  # (e.g. if the topic was deleted between enqueue and run).
  class SecondBrainReply < ::Jobs::Base
    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return if post.blank?

      ::SecondBrain::BotResponder.new(post).respond!
    rescue => e
      Rails.logger.warn("second-brain: reply job error: #{e.class}: #{e.message}")
    end
  end
end
