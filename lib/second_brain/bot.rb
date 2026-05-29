# frozen_string_literal: true

module ::SecondBrain
  # The assistant's Discourse identity. Chats are PMs between a family member
  # and this bot user; the bot posts term-llm's replies.
  module Bot
    module_function

    def username
      SiteSetting.second_brain_bot_username.presence || "stan"
    end

    def user
      existing = ::User.find_by(username_lower: username.downcase)
      return existing if existing

      create!
    end

    def user?(user_id)
      user_id.present? && user_id == user.id
    end

    def create!
      ::User.create!(
        username: ::UserNameSuggester.suggest(username),
        name: username.titleize,
        email: "#{username.downcase}@bot.second-brain.invalid",
        password: SecureRandom.hex(32),
        active: true,
        approved: true,
        trust_level: TrustLevel[1],
      ).tap do |u|
        u.email_tokens.update_all(confirmed: true) if u.respond_to?(:email_tokens)
        u.user_option&.update(
          email_messages_level: ::UserOption.email_level_types[:never],
          email_level: ::UserOption.email_level_types[:never],
        )
      end
    end
  end
end
