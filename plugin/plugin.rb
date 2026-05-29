# frozen_string_literal: true

# name: second-brain
# about: Turns Discourse into a personal knowledge organizer — a clean, Notion-like "second brain". Notes are topics; capture is frictionless.
# version: 0.1.0
# authors: Arpit Jalan
# url: https://github.com/arpitjalan/second-brain

enabled_site_setting :second_brain_enabled

# The homepage UI lives in the companion theme (../theme), which owns the
# custom-homepage modifier and the Blocks layout. This plugin is the backend
# "brain": global setting defaults (db/migrate) today, and the term-llm sidecar
# integration to come.

after_initialize do
  # Milestone 2+ will hook the term-llm reasoning sidecar here:
  #   - on_post_created -> embed / auto-tag / summarize via term-llm HTTP API
  #   - an "ask my brain" endpoint that proxies RAG queries to term-llm
  #     (surfaced as an `ask-my-brain` block registered into the homepage)
end
