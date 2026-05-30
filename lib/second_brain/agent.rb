# frozen_string_literal: true

module ::SecondBrain
  # A reply agent: a Discourse bot user + the term-llm endpoint/token that backs
  # it. Phase 1 has a single shared "family" agent built from the global site
  # settings. The abstraction lives here so later phases can add per-user agents
  # (each its own bot user + container) by extending `resolve`/`all` + a registry
  # — without touching the reply, streaming, or widget code again.
  class Agent
    attr_reader :user, :url, :token, :name, :model, :owner_user_id, :forum_role

    def initialize(user:, url:, token:, name: nil, model: nil, owner_user_id: nil, forum_role: :admin)
      @user = user
      @url = url.to_s
      @token = token.to_s
      @name = name.presence
      @model = model.presence
      @owner_user_id = owner_user_id
      @forum_role = forum_role
    end

    def bot_user_id
      user&.id
    end

    # A shared agent (the family one) has no owner; a personal agent is owned.
    def shared?
      owner_user_id.nil?
    end

    def configured?
      url.present?
    end

    # A term-llm client bound to this agent's endpoint/token/model.
    def client
      TermLlmClient.new(self)
    end

    class << self
      # The shared family agent — the bot named by second_brain_bot_username,
      # backed by the global term-llm settings. Always present.
      def family
        new(
          user: Bot.user,
          url: SiteSetting.second_brain_term_llm_url,
          token: SiteSetting.second_brain_term_llm_api_key,
          model: SiteSetting.second_brain_term_llm_model,
          forum_role: :admin,
        )
      end

      # The agent backing a given bot user, or nil if it isn't an agent.
      # Phase 1: only the family bot resolves. (Phase 2 checks the registry first.)
      def resolve(bot_user)
        return nil if bot_user.nil?
        bot_user.id == Bot.user.id ? family : nil
      end

      # The agent participating in a topic (a chat is a PM with an agent bot), or
      # nil if none is a participant.
      def for_topic(topic)
        return nil if topic.nil?
        bot_id = topic.topic_allowed_users.where(user_id: bot_user_ids).limit(1).pick(:user_id)
        bot_id ? resolve(::User.find_by(id: bot_id)) : nil
      end

      # Every agent (Phase 1: just the family agent).
      def all
        [family]
      end

      # Bot user ids of all agents — used to recognize agent participants/posts.
      def bot_user_ids
        all.map(&:bot_user_id).compact
      end
    end
  end
end
