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

      # Mark it so the homepage "Shared by the family" board can list exactly the
      # chats that were published (not arbitrary forum topics).
      topic.custom_fields["second_brain_shared"] = true
      topic.save_custom_fields(true)

      render json: { url: topic.relative_url }
    end

    # Homepage "living brain" board: the member's recent chats with the bot, and
    # what the family has shared (recent public topics, optionally scoped to the
    # public category).
    def home
      bot_id = Bot.user.id

      recent =
        Topic
          .where(archetype: Archetype.private_message, deleted_at: nil)
          .joins("JOIN topic_allowed_users sb_me ON sb_me.topic_id = topics.id AND sb_me.user_id = #{current_user.id.to_i}")
          .joins("JOIN topic_allowed_users sb_bot ON sb_bot.topic_id = topics.id AND sb_bot.user_id = #{bot_id.to_i}")
          .includes(:user)
          .order(bumped_at: :desc)
          .limit(6)

      shared =
        Topic
          .joins(
            "JOIN topic_custom_fields sb_shared ON sb_shared.topic_id = topics.id AND sb_shared.name = 'second_brain_shared'",
          )
          .where(deleted_at: nil, visible: true)
          .includes(:user)
          .order(bumped_at: :desc)
          .limit(6)
      shared = shared.select { |t| guardian.can_see?(t) }

      render json: {
        recent: recent.map { |t| topic_card(t) },
        shared: shared.map { |t| topic_card(t) },
      }
    end

    # Answer a pending ask_user prompt from the bot. We submit the answers to
    # term-llm (which unblocks the paused run), mark the post answered, and
    # enqueue a job to stream the continuation back into the post.
    def answer
      post = Post.find_by(id: params[:post_id])
      raise Discourse::NotFound if post.blank?
      guardian.ensure_can_see!(post.topic)
      raise Discourse::InvalidAccess unless post.topic&.private_message?

      cancelled = ActiveModel::Type::Boolean.new.cast(params[:cancelled])

      # Serialize concurrent submits (double-tap / two devices) so a late one can't
      # land a term-llm 409 we'd then mis-stamp as expired, clobbering a real answer.
      DistributedMutex.synchronize("second-brain-answer-#{post.id}") do
        public_state = parse_state(post, "second_brain_askuser")
        server_state = parse_state(post, "second_brain_askuser_state")
        raise Discourse::NotFound if public_state.nil? || server_state.nil?
        raise Discourse::InvalidAccess unless public_state["status"] == "pending"
        raise Discourse::InvalidParameters, :call_id unless public_state["call_id"] == params[:call_id]

        answers = cancelled ? nil : build_answers(public_state["questions"] || [], params[:answers])

        begin
          result =
            TermLlmClient.new.submit_ask_user(
              session_id: server_state["session_id"],
              call_id: public_state["call_id"],
              answers: answers,
              cancelled: cancelled,
            )
        rescue TermLlmClient::Expired
          public_state["status"] = "expired"
          post.custom_fields["second_brain_askuser"] = public_state.to_json
          post.save_custom_fields(true)
          return render json: { status: "expired" }, status: 410
        rescue TermLlmClient::Error => e
          return render_json_error e.message, status: 502
        end

        public_state["status"] = "answered"
        public_state["summary"] = result["summary"]
        public_state["skipped"] = true if cancelled
        post.custom_fields["second_brain_askuser"] = public_state.to_json
        post.save_custom_fields(true)

        Jobs.enqueue(:second_brain_reply, post_id: post.id, mode: "resume")
        return render json: { status: "ok", summary: result["summary"], skipped: cancelled }
      end
    end

    private

    def derive_title(message)
      line = message.lines.first.to_s.strip
      line = "New chat" if line.blank?
      line.truncate(80)
    end

    def topic_card(topic)
      {
        title: topic.title,
        url: topic.relative_url,
        username: topic.user&.username,
        age: short_age(topic.bumped_at),
      }
    end

    # Compact relative age ("2m", "3h", "5d", "2w") for the homepage cards.
    def short_age(time)
      return "" if time.nil?
      secs = (Time.now - time).to_i
      return "now" if secs < 60
      mins = secs / 60
      return "#{mins}m" if mins < 60
      hrs = mins / 60
      return "#{hrs}h" if hrs < 24
      days = hrs / 24
      return "#{days}d" if days < 7
      weeks = days / 7
      return "#{weeks}w" if weeks < 52
      "#{days / 365}y"
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
