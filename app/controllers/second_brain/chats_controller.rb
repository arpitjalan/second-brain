# frozen_string_literal: true

module ::SecondBrain
  class ChatsController < ::ApplicationController
    requires_login

    # Start a chat with one message — no title/recipient friction. We create the
    # PM with the bot, derive a throwaway title from the message (term-llm renames
    # it after the first reply), and return its URL so the UI navigates into it.
    def create
      message = params[:message].to_s.strip
      raise Discourse::InvalidParameters, :message if message.blank?

      unless TermLlmClient.configured?
        return render_json_error I18n.t("second_brain.errors.not_configured"), status: 422
      end

      post =
        PostCreator.create!(
          current_user,
          title: derive_title(message),
          raw: message,
          archetype: Archetype.private_message,
          target_usernames: Bot.user.username,
          skip_validations: true,
        )

      render json: { url: post.topic.relative_url }
    end

    # Turn a private chat (PM) into a public topic so the family can see it.
    # We authorize the chat's owner (or staff) here, then perform the conversion
    # as the system user — Discourse only lets staff convert via guardian, but a
    # family member should be able to publish their own chat.
    def make_public
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.blank? || !topic.private_message?

      guardian.ensure_can_see!(topic)
      unless current_user.staff? || topic.user_id == current_user.id
        raise Discourse::InvalidAccess
      end

      category_id = SiteSetting.second_brain_public_category.presence&.to_i

      topic.convert_to_public_topic(Discourse.system_user, category_id: category_id)
      topic.reload
      raise Discourse::InvalidParameters, :topic if topic.private_message?

      render json: { url: topic.relative_url }
    end

    private

    def derive_title(message)
      line = message.lines.first.to_s.strip
      line = "New chat" if line.blank?
      line.truncate(80)
    end
  end
end
