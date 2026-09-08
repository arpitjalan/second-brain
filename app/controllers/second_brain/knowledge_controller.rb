# frozen_string_literal: true

module ::SecondBrain
  class KnowledgeController < ::ApplicationController
    requires_plugin "second-brain"
    requires_login

    MAX_POSTS = 200
    MAX_SOURCE_CHARS = 60_000

    def draft
      topics = KnowledgeDraft.sources(current_user, params.require(:topic_ids))
      agent = Agent.resolve(User.find_by(username_lower: params.require(:agent).to_s.downcase))
      raise Discourse::InvalidAccess unless agent&.usable_by?(current_user)
      RateLimiter.new(current_user, "second-brain-knowledge-draft", 10, 1.hour).performed!

      posts =
        Post
          .where(topic_id: topics.map(&:id), hidden: false, post_type: Post.types[:regular])
          .includes(:user)
          .order(:created_at, :id)
          .limit(MAX_POSTS + 1)
          .to_a
      if posts.size > MAX_POSTS || posts.sum { |post| post.raw.length } > MAX_SOURCE_CHARS
        return render_json_error I18n.t("second_brain.errors.knowledge_too_large"), status: 422
      end
      posts.select! do |post|
        guardian.can_see?(post) && post.raw != I18n.t("second_brain.thinking") &&
          post.custom_fields[BotResponder::STATE_FIELD].blank?
      end
      raise Discourse::InvalidParameters, :topic_ids if posts.empty?
      transcript =
        topics.map do |topic|
          {
            source: "/t/#{topic.id}",
            title: topic.title,
            posts:
              posts
                .select { |post| post.topic_id == topic.id }
                .map do |post|
                  { author: post.user.username, date: post.created_at.iso8601, text: post.raw }
                end,
          }
        end
      draft_id = SecureRandom.hex(16)
      state = {
        status: "queued",
        created_at: Time.now.to_i,
        topic_ids: topics.map(&:id),
        agent_id: agent.user.id,
        transcript: transcript,
      }
      KnowledgeDraft.write(current_user.id, draft_id, state)
      Jobs.enqueue(:second_brain_knowledge_draft, user_id: current_user.id, draft_id: draft_id)
      render json: { draft_id: draft_id }, status: :accepted
    end

    def status
      state = KnowledgeDraft.read(current_user.id, params[:draft_id])
      raise Discourse::NotFound unless state
      topics = KnowledgeDraft.sources(current_user, state["topic_ids"])
      if %w[queued running].include?(state["status"]) &&
           Time.now.to_i - state["created_at"] > KnowledgeDraft::TIMEOUT
        state = state.merge("status" => "failed")
      end
      unless state["status"] == "complete"
        return render json: state.slice("status", "preview", "created_at")
      end

      categories = Category.topic_create_allowed(guardian).order(:position, :id)
      render json: {
               status: "complete",
               title: state["title"],
               raw: state["raw"],
               visibility: "private",
               sources:
                 topics.map { |topic| { id: topic.id, title: topic.title, url: "/t/#{topic.id}" } },
               categories: categories.map { |category| { id: category.id, name: category.name } },
               category_id:
                 categories
                   .find { |category| category.id.to_s == SiteSetting.second_brain_public_category }
                   &.id || categories.first&.id,
             }
    end

    def create
      topics = KnowledgeDraft.sources(current_user, params.require(:topic_ids))
      visibility = params.require(:visibility)
      raise Discourse::InvalidParameters, :visibility if %w[private shared].exclude?(visibility)

      options = {
        title: params.require(:title).to_s.strip,
        raw: params.require(:raw).to_s.strip,
        topic_opts: {
          custom_fields: {
            "second_brain_knowledge_sources" => topics.map(&:id).to_json,
          },
        },
      }
      raise Discourse::InvalidParameters, :raw if options[:raw].blank?
      links =
        topics.each_with_index.map do |topic, index|
          I18n.t("second_brain.knowledge.source", url: "/t/#{topic.id}", number: index + 1)
        end
      options[:raw] += "\n\n---\n\n#{links.join("\n\n")}"

      if visibility == "private"
        options[:archetype] = Archetype.private_message
        options[:target_usernames] = current_user.username
      else
        category = Category.find(params.require(:category_id))
        guardian.ensure_can_create_topic_on_category!(category)
        options[:category] = category.id
      end

      creator = PostCreator.new(current_user, options)
      post = creator.create
      return render_json_error creator.errors.full_messages, status: 422 if creator.errors.present?
      render json: { url: post.topic.relative_url }, status: :created
    end
  end
end
