# frozen_string_literal: true

module ::SecondBrain
  class ChatsController < ::ApplicationController
    requires_plugin "discourse-steward"
    requires_login

    def runtime
      topic, agent = runtime_chat
      models = agent.client.models
      latest = topic.posts.where(user_id: agent.user.id).order(post_number: :desc).first
      reported = JSON.parse(latest&.custom_fields&.dig("second_brain_runtime") || "{}")
      # Older replies predate metadata capture. Inspect their run without changing it.
      if reported.blank? && latest&.reply_to_post_number
        trigger_id = topic.posts.find_by(post_number: latest.reply_to_post_number)&.id
        if trigger_id
          begin
            reported = agent.client.session_runtime("sb_#{topic.id}_#{trigger_id}")
          rescue TermLlmClient::Error
            reported = {}
          end
        end
      end
      render json:
               runtime_selection(topic).merge(
                 models: models,
                 defaults: agent.client.runtime_defaults(models),
                 last_reply: reported,
               )
    rescue TermLlmClient::Error
      render_json_error I18n.t("second_brain.errors.runtime_unavailable"), status: 502
    end

    def agent_runtime
      client = create_agent.client
      models = client.models
      render json: {
               model: "",
               reasoning_effort: "",
               models: models,
               defaults: client.runtime_defaults(models),
             }
    rescue TermLlmClient::Error
      render_json_error I18n.t("second_brain.errors.runtime_unavailable"), status: 502
    end

    def update_runtime
      topic, agent = runtime_chat
      guardian.ensure_can_create_post!(topic)
      runtime_fields(agent).each { |key, value| topic.custom_fields[key] = value }
      topic.save_custom_fields(true)
      render json: runtime_selection(topic)
    rescue TermLlmClient::Error
      render_json_error I18n.t("second_brain.errors.runtime_unavailable"), status: 502
    end

    # Start a chat with one message — no title/recipient friction. We create the
    # PM with the bot, derive a throwaway title from the message (term-llm renames
    # it after the first reply), and return its URL so the UI navigates into it.
    def create
      message = params[:message].to_s.strip
      raise Discourse::InvalidParameters, :message if message.blank?

      agent = create_agent
      unless agent&.configured?
        return render_json_error I18n.t("second_brain.errors.not_configured"), status: 422
      end

      fields = runtime_fields(agent)

      post =
        PostCreator.create!(
          current_user,
          title: derive_title(message),
          raw: message,
          archetype: Archetype.private_message,
          target_usernames: agent.user.username,
          # Topic fields are saved before post_created enqueues the first reply.
          topic_opts: {
            custom_fields: fields,
          },
          skip_validations: true,
        )

      # Spawn the bot's "Thinking…" placeholder now so the chat is alive the instant
      # the member lands in the PM — instead of dead-air until the reply job
      # (Sidekiq pickup) gets around to creating it.
      BotResponder.ensure_placeholder(post, agent)

      render json: { url: post.topic.relative_url }
    rescue TermLlmClient::Error
      render_json_error I18n.t("second_brain.errors.runtime_unavailable"), status: 502
    end

    # Turn a private chat (PM) into a public topic so the family can see it.
    # We authorize the chat's owner (or staff) here, then perform the conversion
    # as the system user — Discourse only lets staff convert via guardian, but a
    # family member should be able to publish their own chat.
    def make_public
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.blank? || !topic.private_message?

      # Only a *bot chat* may be published — never an arbitrary human-to-human PM
      # the caller happens to participate in.
      unless topic.topic_allowed_users.where(user_id: Agent.bot_user_ids).exists?
        raise Discourse::InvalidAccess
      end

      guardian.ensure_can_see!(topic)
      raise Discourse::InvalidAccess unless current_user.staff? || topic.user_id == current_user.id

      category_id = SiteSetting.second_brain_public_category.presence&.to_i

      # Preserve the shared-chat identity when converting to a public topic.
      Topic.transaction do
        topic.convert_to_public_topic(Discourse.system_user, category_id: category_id)
        topic.reload
        raise Discourse::InvalidParameters, :topic if topic.private_message?

        # Marks exactly the chats that were published (not arbitrary forum topics).
        topic.custom_fields["second_brain_shared"] = true
        topic.save_custom_fields(true)
      end

      render json: { url: topic.relative_url }
    end

    # The agents the current member may chat with: the shared family agent + any
    # personal agents they own. Drives the launcher's agent switcher.
    def agents
      list =
        Agent
          .available_to(current_user)
          .filter_map do |a|
            next unless a.user
            {
              username: a.user.username,
              name: a.user.name.presence || a.user.username,
              owned: !a.shared?,
            }
          end
      render json: { agents: list }
    end

    # Answer a pending ask_user prompt from the bot. We submit the answers to
    # term-llm (which unblocks the paused run), mark the post answered, and
    # enqueue a job to stream the continuation back into the post.
    def answer
      post = Post.find_by(id: params[:post_id])
      raise Discourse::NotFound if post.blank?
      guardian.ensure_can_see!(post.topic)
      raise Discourse::InvalidAccess unless post.topic&.private_message?

      # A personal agent's run is private to its owner — being a PM participant
      # (e.g. invited in later) is not enough to drive/answer it.
      agent = Agent.for_topic(post.topic) || Agent.family
      raise Discourse::InvalidAccess unless agent.usable_by?(current_user)

      cancelled = ActiveModel::Type::Boolean.new.cast(params[:cancelled])

      # Serialize concurrent submits (double-tap / two devices) so a late one can't
      # land a term-llm 409 we'd then mis-stamp as expired, clobbering a real answer.
      # validity > worst-case in-lock budget (term-llm open 10s + read 30s + DB),
      # so the lock can't auto-expire mid-submit and let a concurrent answer race.
      DistributedMutex.synchronize("second-brain-answer-#{post.id}", validity: 90) do
        public_state = parse_state(post, "second_brain_askuser")
        server_state = parse_state(post, "second_brain_askuser_state")
        raise Discourse::NotFound if public_state.nil? || server_state.nil?
        raise Discourse::InvalidAccess unless public_state["status"] == "pending"
        unless public_state["call_id"] == params[:call_id]
          raise Discourse::InvalidParameters, :call_id
        end

        answers = cancelled ? nil : build_answers(public_state["questions"] || [], params[:answers])

        begin
          result =
            agent.client.submit_ask_user(
              session_id: server_state["session_id"],
              call_id: public_state["call_id"],
              answers: answers,
              cancelled: cancelled,
            )
        rescue TermLlmClient::Expired
          public_state["status"] = "expired"
          post.custom_fields["second_brain_askuser"] = public_state.to_json
          post.save_custom_fields(true)
          return render json: { status: "expired" }, status: :gone
        rescue TermLlmClient::Error => e
          return render_json_error e.message, status: 502
        end

        public_state["status"] = "answered"
        public_state["summary"] = result["summary"]
        public_state["skipped"] = true if cancelled
        post.custom_fields["second_brain_askuser"] = public_state.to_json
        post.save_custom_fields(true)
        # Restart the watchdog's staleness clock from the answer (a question may
        # have sat pending for a long time); otherwise the just-answered post looks
        # instantly abandoned and the watchdog could race the resume job below.
        post.update_columns(updated_at: Time.zone.now)

        # Collapse the inline form to its answered summary on live clients the
        # instant the answer lands. The resume job re-renders the post, and the
        # client's cached "pending" ask_user state would otherwise re-paint the
        # already-answered form (from a stale field) until a reload.
        ::SecondBrain::BotResponder.publish_askuser(post, public_state)

        Jobs.enqueue(:second_brain_reply, post_id: post.id, mode: "resume")
        return render json: { status: "ok", summary: result["summary"], skipped: cancelled }
      end
    end

    private

    def runtime_fields(agent)
      model = params[:model].to_s.strip
      effort = params[:reasoning_effort].to_s.strip
      if model.present?
        selected = agent.client.models.find { |entry| entry[:id] == model }
        raise Discourse::InvalidParameters, :model unless selected
        if effort.present? && !selected[:efforts].include?(effort)
          raise Discourse::InvalidParameters, :reasoning_effort
        end
      elsif effort.present?
        raise Discourse::InvalidParameters, :reasoning_effort
      end
      { "second_brain_model" => model.presence, "second_brain_reasoning_effort" => effort.presence }
    end

    def runtime_chat
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic&.private_message?
      guardian.ensure_can_see!(topic)
      agent = Agent.for_topic(topic)
      raise Discourse::InvalidAccess unless agent&.usable_by?(current_user)
      [topic, agent]
    end

    def runtime_selection(topic)
      {
        model: topic.custom_fields["second_brain_model"].to_s,
        reasoning_effort: topic.custom_fields["second_brain_reasoning_effort"].to_s,
      }
    end

    # Which agent a new chat is with. With no `agent` param: the member's own
    # personal agent if they have one, else the family agent. With a param: that
    # agent — but a personal agent only its owner may chat with.
    def create_agent
      requested = params[:agent].to_s.strip
      return Agent.owned_by(current_user).first || Agent.family if requested.blank?

      agent = Agent.resolve(::User.find_by(username_lower: requested.downcase))
      raise Discourse::InvalidParameters, :agent if agent.nil?
      raise Discourse::InvalidAccess unless agent.usable_by?(current_user)
      agent
    end

    def derive_title(message)
      line = message.lines.first.to_s.strip
      line = "New chat" if line.blank?
      line.truncate(80)
    end

    def parse_state(post, field)
      raw = post.custom_fields[field]
      return nil if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    # Build the term-llm answer array from the client params, validating shape.
    # term-llm re-validates, but we guard here too (single-select needs a
    # selection or custom text; multi-select needs a non-empty list).
    def build_answers(questions, raw_answers)
      raw = raw_answers.is_a?(Array) ? raw_answers : []
      raise Discourse::InvalidParameters, :answers if raw.length != questions.length

      questions.each_with_index.map do |question, index|
        answer = raw[index] || {}
        header = question["header"].to_s

        if question["multi_select"]
          list = Array(answer["selected_list"]).map(&:to_s).map(&:strip).reject(&:blank?)
          raise Discourse::InvalidParameters, :answers if list.empty?
          {
            question_index: index,
            header: header,
            selected_list: list,
            is_custom: false,
            is_multi_select: true,
          }
        else
          selected = answer["selected"].to_s.strip
          raise Discourse::InvalidParameters, :answers if selected.blank?
          {
            question_index: index,
            header: header,
            selected: selected,
            is_custom: answer["is_custom"] ? true : false,
            is_multi_select: false,
          }
        end
      end
    end
  end
end
