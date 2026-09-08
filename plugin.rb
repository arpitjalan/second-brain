# frozen_string_literal: true

# name: discourse-steward
# about: Discourse Steward — private AI conversations, shared knowledge, and interactive widgets powered by term-llm.
# version: 0.2.0
# authors: Arpit Jalan
# url: https://discourse-steward.netlify.app/

# Persisted settings, data, jobs, and API paths retain their legacy identifiers.
# See docs/rename.md before changing any second_brain / second-brain keys.
enabled_site_setting :second_brain_enabled

register_asset "stylesheets/common/discourse-steward.scss"

register_svg_icon "paper-plane"
register_svg_icon "globe"
register_svg_icon "book-open"
register_svg_icon "puzzle-piece"
register_svg_icon "arrows-rotate"
register_svg_icon "up-right-from-square"
register_svg_icon "expand"
register_svg_icon "copy"
register_svg_icon "check"
register_svg_icon "paperclip"
register_svg_icon "xmark"
register_svg_icon "magnifying-glass"

# Take over the homepage from the plugin itself — no separate theme needed.
# HomepageHelper#resolve returns "custom" when this modifier is truthy, routing
# the homepage to discovery/custom. Its `custom-homepage` plugin outlet renders
# our connector (assets/javascripts/discourse/connectors/custom-homepage/).
register_modifier(:custom_homepage_enabled) { true }

# Plain-Ruby libs (reference Rails consts only inside methods, so top-level
# require is safe). NOTE: this plugin is symlinked into plugins/, and Discourse
# does NOT add a symlinked plugin's app/ + lib dirs to Rails autoload paths, so
# we require everything explicitly (no Zeitwerk conflict — not on an autoload path).
require_relative "lib/second_brain/term_llm_client"
require_relative "lib/second_brain/bot"
require_relative "lib/second_brain/agent"
require_relative "lib/second_brain/bot_responder"
require_relative "lib/second_brain/knowledge_draft"

after_initialize do
  # app/ classes inherit Rails base classes at load time, so require them here
  # (after the app — ApplicationController, ActiveRecord::Base, Jobs::Base — has loaded).
  require_relative "app/models/second_brain/agent_record"
  require_relative "app/jobs/regular/second_brain_reply"
  require_relative "app/jobs/regular/second_brain_knowledge_draft"
  require_relative "app/jobs/scheduled/second_brain_watchdog"
  require_relative "app/controllers/second_brain/chats_controller"
  require_relative "app/controllers/second_brain/knowledge_controller"
  require_relative "app/controllers/second_brain/widgets_controller"

  # Chats are PMs with the bot user. When a family member posts in such a PM,
  # the bot replies with term-llm's answer (off-request, in a job).
  on(:post_created) { |post| SecondBrain::BotResponder.maybe_respond(post) }

  # Interactive ask_user state on the bot's post. The public field (questions /
  # status / summary) is exposed to the client to render the form; the state
  # field (session_id / response_id / sequence / pre-prompt text) is server-only.
  register_post_custom_field_type("second_brain_askuser", :string)
  register_post_custom_field_type("second_brain_askuser_state", :string)

  # Marks a chat that's been published to the family (scopes the shared-chat
  # results in ChatsController#search).
  register_topic_custom_field_type("second_brain_shared", :boolean)
  register_topic_custom_field_type("second_brain_knowledge_sources", :string)
  register_topic_custom_field_type("second_brain_model", :string)
  register_topic_custom_field_type("second_brain_reasoning_effort", :string)
  register_post_custom_field_type("second_brain_runtime", :string)

  # Expose only the public ask_user field to the client (preloaded in topic
  # views via the allowlister), parsed to an object the form renderer reads.
  topic_view_post_custom_fields_allowlister do |_user, _topic|
    %w[second_brain_askuser second_brain_runtime]
  end

  add_to_serializer(
    :post,
    :second_brain_runtime,
    include_condition: -> { post_custom_fields.key?("second_brain_runtime") },
  ) do
    JSON.parse(post_custom_fields["second_brain_runtime"])
  rescue StandardError
    nil
  end

  # Works in both paths: topic-view loads (preloaded via the allowlister) and the
  # single-post `:revised` refetch (no topic_view → object.custom_fields).
  add_to_serializer(
    :post,
    :second_brain_askuser,
    include_condition: -> { post_custom_fields.key?("second_brain_askuser") },
  ) do
    JSON.parse(post_custom_fields["second_brain_askuser"])
  rescue StandardError
    nil
  end

  add_to_serializer(
    :topic_view,
    :second_brain_agent,
    include_condition: -> { object.topic.private_message? },
  ) do
    agent = SecondBrain::Agent.for_topic(object.topic)
    if agent&.user
      { username: agent.user.username, name: agent.user.name.presence || agent.user.username }
    end
  end

  Discourse::Application.routes.append do
    # Search the member's own bot chats (+ shared public chats).
    # The agents this member may chat with (family + their own) — for the switcher.
    get "/second-brain/agents" => "second_brain/chats#agents"
    get "/second-brain/knowledge/drafts/:draft_id" => "second_brain/knowledge#status"
    post "/second-brain/knowledge/draft" => "second_brain/knowledge#draft"
    post "/second-brain/knowledge" => "second_brain/knowledge#create"
    get "/second-brain/agent-runtime" => "second_brain/chats#agent_runtime"
    # Start a chat from a single message (frictionless homepage box).
    post "/second-brain/chats" => "second_brain/chats#create"
    get "/second-brain/chats/:topic_id/runtime" => "second_brain/chats#runtime"
    put "/second-brain/chats/:topic_id/runtime" => "second_brain/chats#update_runtime"
    # Turn a private chat into a public topic.
    post "/second-brain/chats/:topic_id/make_public" => "second_brain/chats#make_public"
    # Answer a pending ask_user prompt (resumes the paused run).
    post "/second-brain/answer" => "second_brain/chats#answer"
    # List the term-llm widgets across the member's agents (for the sidebar).
    get "/second-brain/list-widgets" => "second_brain/widgets#index"
    # Proxy a specific agent's widget pages/assets (with that agent's token).
    # Forward writes too (POST/PUT/PATCH/DELETE) so interactive widgets work.
    match "/second-brain/agent-widgets/:agent/*path" => "second_brain/widgets#show",
          :format => false,
          :via => %i[get post put patch delete]
    # Legacy/family widget proxy (no agent segment) — keeps old embeds working.
    match "/second-brain/widgets/*path" => "second_brain/widgets#show",
          :format => false,
          :via => %i[get post put patch delete]
  end
end
