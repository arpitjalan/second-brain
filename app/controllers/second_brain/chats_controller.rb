# frozen_string_literal: true

module ::SecondBrain
  class ChatsController < ::ApplicationController
    requires_login

    # Turn a private chat (PM) into a public topic so the family can see it.
    def make_public
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.blank? || !topic.private_message?

      guardian.ensure_can_see!(topic)
      unless topic.user_id == current_user.id || current_user.staff?
        raise Discourse::InvalidAccess
      end

      category_id = SiteSetting.second_brain_public_category.presence&.to_i
      category_id ||= SiteSetting.uncategorized_category_id

      topic.convert_to_public_topic(current_user, category_id: category_id)
      render json: { url: topic.reload.relative_url }
    end
  end
end
