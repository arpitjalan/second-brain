# frozen_string_literal: true

module ::SecondBrain
  class ChatsController < ::ApplicationController
    requires_plugin "second-brain"
    requires_login

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

      post =
        PostCreator.create!(
          current_user,
          title: derive_title(message),
          raw: message,
          archetype: Archetype.private_message,
          target_usernames: agent.user.username,
          skip_validations: true,
        )

      # Spawn the bot's "Thinking…" placeholder now so the chat is alive the instant
      # the member lands in the PM — instead of dead-air until the reply job
      # (Sidekiq pickup) gets around to creating it.
      BotResponder.ensure_placeholder(post.topic, agent)

      render json: { url: post.topic.relative_url }
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
      unless current_user.staff? || topic.user_id == current_user.id
        raise Discourse::InvalidAccess
      end

      category_id = SiteSetting.second_brain_public_category.presence&.to_i

      # Convert + mark-shared together so we never end up public-but-unmarked
      # (invisible to the homepage "Shared by the family" board).
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
        Agent.available_to(current_user).filter_map do |a|
          next unless a.user
          {
            username: a.user.username,
            name: a.user.name.presence || a.user.username,
            owned: !a.shared?,
          }
        end
      render json: { agents: list }
    end

    # Homepage "living brain" board: the member's recent chats with the bot, and
    # a column of interesting public topics worth a look.
    def home
      agent_ids = Agent.bot_user_ids
      bot_ids_sql = agent_ids_sql(agent_ids)
      limit = SiteSetting.second_brain_board_topics

      # The member's recent chats with any agent bot they participate in (the
      # sb_me join keeps it to their own chats — personal agents stay private).
      recent =
        Topic
          .where(archetype: Archetype.private_message, deleted_at: nil)
          .joins("JOIN topic_allowed_users sb_me ON sb_me.topic_id = topics.id AND sb_me.user_id = #{current_user.id.to_i}")
          .joins("JOIN topic_allowed_users sb_bot ON sb_bot.topic_id = topics.id AND sb_bot.user_id IN (#{bot_ids_sql})")
          .includes(:user)
          .order(bumped_at: :desc)
          .limit(limit)

      render json: {
        recent: recent.map { |t| topic_card(t) },
        interesting: interesting_topics(agent_ids, limit).map { |t| topic_card(t) },
      }
    end

    # Full-text search over the member's OWN bot chats (PMs they participate in) +
    # shared public chats. Privacy is structural: the candidate topic-id set is the
    # exact owner/bot scope used by #home, so another member's private chats are
    # never even searched; every hit is also re-gated through guardian.can_see?.
    def search
      query = params[:q].to_s.strip
      return render json: { results: [] } if query.length < 2

      ids = searchable_topic_ids
      return render json: { results: [] } if ids.empty?

      term = Search.prepare_data(query)
      return render json: { results: [] } if term.blank?

      limit = SiteSetting.second_brain_search_results

      # `Search.ts_query` escapes/unaccents the term and returns a complete
      # TO_TSQUERY(...) SQL fragment, so this is injection-safe; the topic_id bound
      # keeps the @@ match tiny. Search bodies (question + answer) of regular,
      # non-hidden, non-deleted posts only.
      posts =
        Post
          .where(topic_id: ids, post_type: Post.types[:regular], hidden: false, deleted_at: nil)
          .joins("JOIN post_search_data psd ON psd.post_id = posts.id")
          .joins(:topic)
          .where("psd.search_data @@ #{Search.ts_query(term: term)}")
          .preload(topic: :user)
          .order("topics.bumped_at DESC, posts.post_number ASC")
          .limit(limit * 3)

      seen = Set.new
      results = []
      posts.each do |post|
        topic = post.topic
        next if topic.nil? || seen.include?(topic.id)
        next unless guardian.can_see?(topic)
        seen << topic.id
        results << search_card(post, topic, query)
        break if results.size >= limit
      end

      render json: { results: results }
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
      if !agent.shared? && agent.owner_user_id != current_user.id
        raise Discourse::InvalidAccess
      end

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
        raise Discourse::InvalidParameters, :call_id unless public_state["call_id"] == params[:call_id]

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

        Jobs.enqueue(:second_brain_reply, post_id: post.id, mode: "resume")
        return render json: { status: "ok", summary: result["summary"], skipped: cancelled }
      end
    end

    private

    # Which agent a new chat is with. With no `agent` param: the member's own
    # personal agent if they have one, else the family agent. With a param: that
    # agent — but a personal agent only its owner may chat with.
    def create_agent
      requested = params[:agent].to_s.strip
      return Agent.owned_by(current_user).first || Agent.family if requested.blank?

      agent = Agent.resolve(::User.find_by(username_lower: requested.downcase))
      raise Discourse::InvalidParameters, :agent if agent.nil?
      raise Discourse::InvalidAccess unless agent.shared? || agent.owner_user_id == current_user.id
      agent
    end

    # The topics #search may look in: the caller's own bot PMs (the exact sb_me/
    # sb_bot scope from #home — sb_me restricts to PMs the caller participates in,
    # sb_bot to bot chats) + public chats shared to the family. uniq'd id list.
    def searchable_topic_ids
      bot_ids_sql = agent_ids_sql(Agent.bot_user_ids)
      me = current_user.id.to_i

      pm_ids =
        Topic
          .where(archetype: Archetype.private_message, deleted_at: nil)
          .joins("JOIN topic_allowed_users sb_me ON sb_me.topic_id = topics.id AND sb_me.user_id = #{me}")
          .joins("JOIN topic_allowed_users sb_bot ON sb_bot.topic_id = topics.id AND sb_bot.user_id IN (#{bot_ids_sql})")
          .pluck(:id)

      public_ids =
        Topic
          .where(archetype: Archetype.default, deleted_at: nil, visible: true)
          .joins(
            "JOIN topic_custom_fields sb ON sb.topic_id = topics.id AND sb.name = 'second_brain_shared'",
          )
          .pluck(:id)

      (pm_ids + public_ids).uniq
    end

    def search_card(post, topic, query)
      {
        title: topic.title,
        url: "#{topic.relative_url}/#{post.post_number}",
        username: topic.user&.username,
        blurb: Search::GroupedSearchResults.blurb_for(cooked: post.cooked, term: query),
        age: short_age(topic.bumped_at),
      }
    end

    # A safe `IN (...)` list of agent bot user ids (ints; never empty).
    def agent_ids_sql(ids)
      list = Array(ids).map(&:to_i)
      list = [Bot.user.id.to_i] if list.empty?
      list.join(",")
    end

    # The homepage's right column: public topics worth a look, prioritized
    # shared (published bot chats) → agent-created → hot/recently-active, deduped
    # and capped at `limit`. The last tier is a never-empty fallback. Only topics
    # the member can see are included.
    def interesting_topics(agent_ids, limit)
      picked = []
      seen = Set.new

      gather =
        lambda do |scope|
          scope.each do |topic|
            break if picked.size >= limit
            next if seen.include?(topic.id) || !guardian.can_see?(topic)
            seen << topic.id
            picked << topic
          end
        end

      public_topics =
        Topic.where(archetype: Archetype.default, deleted_at: nil, visible: true).includes(:user)

      # 1) Published "shared" chats.
      gather.call(
        public_topics
          .joins("JOIN topic_custom_fields sb ON sb.topic_id = topics.id AND sb.name = 'second_brain_shared'")
          .order(bumped_at: :desc)
          .limit(limit),
      )

      # 2) Topics any agent created on the forum.
      if picked.size < limit
        gather.call(public_topics.where(user_id: agent_ids).order(created_at: :desc).limit(limit))
      end

      # 3) Hot / recently-active topics — the fallback so the column is never empty.
      if picked.size < limit
        gather.call(public_topics.order(bumped_at: :desc).limit(limit * 3))
      end

      picked
    end

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
