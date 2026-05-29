# frozen_string_literal: true

module ::SecondBrain
  class ChatsController < ::ApplicationController
    requires_login

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

      # Blank → let TopicConverter pick a valid public category (it avoids
      # Uncategorized, which is disabled here).
      category_id = SiteSetting.second_brain_public_category.presence&.to_i

      topic.convert_to_public_topic(Discourse.system_user, category_id: category_id)
      topic.reload
      raise Discourse::InvalidParameters, :topic if topic.private_message?

      render json: { url: topic.relative_url }
    end
  end
end
