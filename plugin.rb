# frozen_string_literal: true

# name: second-brain
# about: Turns Discourse into a personal knowledge organizer — a clean, Notion-like "second brain". Notes are topics; capture is frictionless.
# version: 0.1.0
# authors: Arpit Jalan
# url: https://github.com/arpitjalan/second-brain

enabled_site_setting :second_brain_enabled

register_asset "stylesheets/common/second-brain.scss"

register_svg_icon "paper-plane"

# Take over the homepage from the plugin itself — no separate theme needed.
# HomepageHelper#resolve returns "custom" when this modifier is truthy, routing
# the homepage to discovery/custom. Its `custom-homepage` plugin outlet renders
# our connector (assets/javascripts/discourse/connectors/custom-homepage/).
register_modifier(:custom_homepage_enabled) { true }

require_relative "lib/second_brain/term_llm_client"

after_initialize do
  # Discourse is the UI for term-llm: this endpoint proxies questions to the
  # term-llm server (Bearer token stays server-side) and returns the answer.
  # Streaming + the agentic /v1/responses path (web search, widgets) build here.
  #
  # NOTE: this plugin is symlinked into plugins/, and Discourse does not add a
  # symlinked plugin's app/ dirs to Rails' autoload paths — so app/ classes
  # won't autoload. We require the controller explicitly (no Zeitwerk conflict
  # precisely because it isn't on an autoload path).
  require_relative "app/controllers/second_brain/ask_controller"

  Discourse::Application.routes.append do
    post "/second-brain/ask" => "second_brain/ask#create"
  end
end
