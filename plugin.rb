# frozen_string_literal: true

# name: second-brain
# about: Turns Discourse into a personal knowledge organizer — a clean, Notion-like "second brain". Notes are topics; capture is frictionless.
# version: 0.1.0
# authors: Arpit Jalan
# url: https://github.com/arpitjalan/second-brain

enabled_site_setting :second_brain_enabled

register_asset "stylesheets/common/second-brain.scss"

register_svg_icon "paper-plane"
register_svg_icon "globe"
register_svg_icon "puzzle-piece"
register_svg_icon "arrows-rotate"
register_svg_icon "up-right-from-square"
register_svg_icon "expand"
register_svg_icon "copy"
register_svg_icon "check"
register_svg_icon "paperclip"
register_svg_icon "xmark"

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
require_relative "lib/second_brain/bot_responder"

after_initialize do
  # app/ classes inherit Rails base classes at load time, so require them here
  # (after the app — ApplicationController, Jobs::Base — has loaded).
  require_relative "app/jobs/regular/second_brain_reply"
  require_relative "app/controllers/second_brain/chats_controller"
  require_relative "app/controllers/second_brain/widgets_controller"

  # Chats are PMs with the bot user. When a family member posts in such a PM,
  # the bot replies with term-llm's answer (off-request, in a job).
  on(:post_created) { |post| SecondBrain::BotResponder.maybe_respond(post) }

  # Interactive ask_user state on the bot's post. The public field (questions /
  # status / summary) is exposed to the client to render the form; the state
  # field (session_id / response_id / sequence / pre-prompt text) is server-only.
  register_post_custom_field_type("second_brain_askuser", :string)
  register_post_custom_field_type("second_brain_askuser_state", :string)

  # Marks a chat that's been published to the family (for the homepage board).
  register_topic_custom_field_type("second_brain_shared", :boolean)

  # Expose only the public ask_user field to the client (preloaded in topic
  # views via the allowlister), parsed to an object the form renderer reads.
  topic_view_post_custom_fields_allowlister { |_user, _topic| ["second_brain_askuser"] }

  # Works in both paths: topic-view loads (preloaded via the allowlister) and the
  # single-post `:revised` refetch (no topic_view → object.custom_fields).
  add_to_serializer(
    :post,
    :second_brain_askuser,
    include_condition: -> { post_custom_fields.key?("second_brain_askuser") },
  ) { JSON.parse(post_custom_fields["second_brain_askuser"]) rescue nil }

  Discourse::Application.routes.append do
    # Homepage board: the member's recent chats + what the family shared.
    get "/second-brain/home" => "second_brain/chats#home"
    # Start a chat from a single message (frictionless homepage box).
    post "/second-brain/chats" => "second_brain/chats#create"
    # Turn a private chat into a public topic.
    post "/second-brain/chats/:topic_id/make_public" => "second_brain/chats#make_public"
    # Answer a pending ask_user prompt (resumes the paused run).
    post "/second-brain/answer" => "second_brain/chats#answer"
    # List the family's term-llm widgets (for the sidebar).
    get "/second-brain/list-widgets" => "second_brain/widgets#index"
    # Proxy term-llm widget pages/assets (with the Bearer token, server-side).
    get "/second-brain/widgets/*path" => "second_brain/widgets#show", format: false
  end
end
