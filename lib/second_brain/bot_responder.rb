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

    def respond!
      return unless @topic&.private_message?

      messages = build_messages
      return if messages.empty?

      answer = TermLlmClient.new.complete(messages).to_s.strip
      return if answer.blank?

      PostCreator.create!(Bot.user, topic_id: @topic.id, raw: answer, skip_validations: true)
    end

    private

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
