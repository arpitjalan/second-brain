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
  require_relative "app/controllers/second_brain/ask_controller"
  require_relative "app/controllers/second_brain/chats_controller"
  require_relative "app/controllers/second_brain/widgets_controller"

  # Chats are PMs with the bot user. When a family member posts in such a PM,
  # the bot replies with term-llm's answer (off-request, in a job).
  on(:post_created) { |post| SecondBrain::BotResponder.maybe_respond(post) }

  Discourse::Application.routes.append do
    # Legacy one-shot proxy (homepage chat on `main`); harmless here.
    post "/second-brain/ask" => "second_brain/ask#create"
    # Start a chat from a single message (frictionless homepage box).
    post "/second-brain/chats" => "second_brain/chats#create"
    # Turn a private chat into a public topic.
    post "/second-brain/chats/:topic_id/make_public" => "second_brain/chats#make_public"
    # List the family's term-llm widgets (for the sidebar).
    get "/second-brain/list-widgets" => "second_brain/widgets#index"
    # Proxy term-llm widget pages/assets (with the Bearer token, server-side).
    get "/second-brain/widgets/*path" => "second_brain/widgets#show", format: false
  end
end
