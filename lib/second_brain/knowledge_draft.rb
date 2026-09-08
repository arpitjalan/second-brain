# frozen_string_literal: true

module ::SecondBrain
  class KnowledgeDraft
    MAX_TOPICS = 5
    TTL = 1.hour
    TIMEOUT = 10.minutes

    def self.key(user_id, draft_id)
      raise Discourse::InvalidParameters, :draft_id unless draft_id.to_s.match?(/\A[0-9a-f]{32}\z/)
      "second-brain:knowledge:#{user_id}:#{draft_id}"
    end

    def self.read(user_id, draft_id)
      value = Discourse.redis.get(key(user_id, draft_id))
      JSON.parse(value) if value
    end

    def self.write(user_id, draft_id, state)
      Discourse.redis.setex(key(user_id, draft_id), TTL, state.to_json)
    end

    def self.sources(user, source_ids)
      ids = Array(source_ids).map { |id| Integer(id.to_s, exception: false) }.uniq
      if ids.empty? || ids.size > MAX_TOPICS || ids.any? { |id| id.nil? || id <= 0 }
        raise Discourse::InvalidParameters, :topic_ids
      end
      guardian = user.guardian
      ids.map do |id|
        topic = Topic.find(id)
        guardian.ensure_can_see!(topic)
        if topic.private_message?
          agent = Agent.for_topic(topic)
          unless topic.topic_allowed_users.exists?(user_id: user.id) && agent&.usable_by?(user)
            raise Discourse::InvalidAccess
          end
        elsif !topic.visible || !topic.custom_fields["second_brain_shared"]
          raise Discourse::InvalidAccess
        end
        topic
      end
    end
  end
end
