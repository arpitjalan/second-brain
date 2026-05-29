# frozen_string_literal: true

module ::Jobs
  # Calls term-llm for a chat (PM) and posts the bot's reply, off the request.
  class SecondBrainReply < ::Jobs::Base
    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return if post.blank?

      ::SecondBrain::BotResponder.new(post).respond!
    end
  end
end
