# Second Brain

Turns Discourse into a personal knowledge organizer — a calm, Notion-flavored
"second brain" rather than a public community. A **note** is a Discourse topic;
replies are sub-thoughts / annotations.

Single repo, single plugin: it carries the Ruby backend, the Ember frontend
(capture box + reskin), and the styles together.

## Roadmap

- **M1 — Reskin (this milestone).** Capture box pinned to the homepage, notes
  rendered as cards, and the forum/social chrome (likes, badges, trust levels,
  avatars, view/reply/post counts) stripped away.
- **M2 — term-llm sidecar.** Run [term-llm](https://term-llm.com) as a local
  HTTP service. On new note: embed + auto-tag + summarize. Add an "ask my brain"
  RAG panel. See `plugin.rb` `after_initialize` for the hook points.

## Layout

```
plugin.rb                                  metadata, asset + setting registration
config/settings.yml                        site settings
config/locales/{client,server}.en.yml      strings
assets/stylesheets/second-brain.scss       the reskin
assets/javascripts/discourse/
  components/capture-box.gjs               the capture component
  connectors/above-main-container/         injects capture box atop the homepage
```

## Settings — applied automatically on install

The calm layout comes from Discourse's own settings, not CSS hacks. A migration
(`db/migrate/…_configure_second_brain_defaults.rb`) seeds these on install via
`INSERT … ON CONFLICT (name) DO NOTHING`, so a fresh site gets the full
experience for free — and an existing site that already customized one of these
keeps its own value (we never clobber a deliberate choice):

| Setting | Value | Why |
|---|---|---|
| `enable_welcome_banner` | `false` | Kills the "Welcome, …" banner + its search (the capture box replaces it) |
| `top_menu` | `latest` | Collapses the Latest/Hot/Categories nav pills |
| `enable_chat` | `false` | Removes the CHANNELS sidebar section |
| `post_menu` | default minus `like` | Drops the Like button on posts (read from the live default, so it's version-safe) |

Two things stay manual (no yaml toggle exists, and they're per-taste):

- `second_brain_capture_category` — the category captured notes land in (optional).
- Sidebar **sections** — tailor under **Admin → Customize → Sidebar**, or switch
  `navigation_menu` to `header_dropdown` to drop the left rail entirely.

The CSS then only does what settings can't: card styling/contrast, spacing,
typography, and hiding avatars + view/reply counts.

## Try it

1. Enable the plugin — it builds with Discourse and `db:migrate` seeds the
   settings above; no manual flipping.
2. Open the homepage: type a thought, press Enter — the first line becomes the
   note title, the rest prefills the body, and the composer opens.

The SCSS selectors target current Discourse markup and may need small tweaks
against your running instance.
