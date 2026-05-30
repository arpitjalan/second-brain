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

      # The agent backing a given bot user: a registry row if present, else the
      # family agent for the family bot, else nil.
      def resolve(bot_user)
        return nil if bot_user.nil?
        row = registry_row_for(bot_user.id)
        return from_record(row) if row
        bot_user.id == Bot.user.id ? family : nil
      end

      # The agent participating in a topic (a chat is a PM with an agent bot), or
      # nil if none is a participant.
      def for_topic(topic)
        return nil if topic.nil?
        bot_id = topic.topic_allowed_users.where(user_id: bot_user_ids).limit(1).pick(:user_id)
        bot_id ? resolve(::User.find_by(id: bot_id)) : nil
      end

      # Every agent: the registry rows + the family agent (unless it has a row).
      def all
        agents = registry_agents
        agents << family unless agents.any? { |a| a.bot_user_id == Bot.user.id }
        agents
      end

      # Agents owned by (personal to) a given user.
      def owned_by(user)
        return [] if user.nil?
        all.select { |a| a.owner_user_id == user.id }
      end

      # The agents a user may chat with: the shared family agent + their own.
      def available_to(user)
        ([family] + owned_by(user)).uniq(&:bot_user_id)
      end

      # Bot user ids of all agents — used to recognize agent participants/posts.
      def bot_user_ids
        all.map(&:bot_user_id).compact
      end

      private

      def registry_agents
        AgentRecord
          .order(:id)
          .filter_map do |row|
            agent = from_record(row)
            agent if agent.user # skip rows whose bot user was deleted
          end
      rescue ActiveRecord::StatementInvalid
        [] # table not migrated yet — behave like a single (family) agent
      end

      def registry_row_for(bot_user_id)
        AgentRecord.find_by(bot_user_id: bot_user_id)
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def from_record(row)
        new(
          user: ::User.find_by(id: row.bot_user_id),
          url: row.term_llm_url,
          token: row.term_llm_token,
          name: row.agent_name,
          model: row.model,
          owner_user_id: row.owner_user_id,
          forum_role: (row.forum_role.presence || "tl4").to_sym,
        )
      end
    end
  end
end
