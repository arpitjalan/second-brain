# frozen_string_literal: true

# name: second-brain
# about: Turns Discourse into a personal knowledge organizer — a clean, Notion-like "second brain". Notes are topics; capture is frictionless.
# version: 0.1.0
# authors: Arpit Jalan
# url: https://github.com/arpitjalan/second-brain

enabled_site_setting :second_brain_enabled

register_asset "stylesheets/second-brain.scss"

register_svg_icon "plus"
register_svg_icon "bolt"

after_initialize do
  # Milestone 2+ will hook the term-llm reasoning sidecar here:
  #   - on_post_created -> embed / auto-tag / summarize via term-llm HTTP API
  #   - an "ask my brain" endpoint that proxies RAG queries to term-llm
  # For Milestone 1 (the reskin) no server-side behavior is needed.
end
