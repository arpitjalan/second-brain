# Second Brain

Turn Discourse into a personal knowledge organizer — a calm, Notion-flavored
"second brain" rather than a public community. A **note** is a Discourse topic;
replies are sub-thoughts / annotations.

One repo, two artifacts:

```
plugin/   Discourse plugin — the backend "brain"
          · seeds calm global setting defaults (db/migrate)
          · (M2) term-llm sidecar: embed / auto-tag / "ask my brain"
          Symlinked into a Discourse checkout at plugins/second-brain.

theme/    Discourse theme — owns the homepage UI
          · custom_homepage modifier → takes over the homepage route
          · Blocks API layout: a capture block + a recent-notes block
          Installed via Admin → Customize → Themes.
```

## Why a plugin *and* a theme

The homepage is replaced via Discourse's `custom_homepage` **theme modifier** —
a plugin cannot set it, so the UI half must be a theme. The reasoning/back end
(term-llm, setting seeds) is a plugin. They're developed together here.

## Architecture

```
theme (custom_homepage) ──► homepage-blocks outlet
                              ├─ second-brain-capture      (opens composer)
                              └─ second-brain-recent-notes (latest topics)
plugin ──► global setting seeds today;  (M2) term-llm HTTP sidecar
                              └─ (M2) ask-my-brain block → RAG over your notes
```

## Status

- **M1 — homepage reskin (in progress):** capture + recent-notes blocks on a
  custom homepage. Built on the **Blocks API**, which is marked `@experimental`
  in core — expect to track changes.
- **M2 — term-llm sidecar:** see `plugin/plugin.rb` `after_initialize`.

## Install (dev)

1. **Plugin:** already symlinked into your Discourse checkout at
   `plugins/second-brain`; it builds with Discourse. `db:migrate` seeds the
   global setting defaults (see `plugin/README.md`).
2. **Theme:** Admin → Customize → Themes → Install → *From your device / git*,
   pointing at the `theme/` directory (or use the `discourse_theme` CLI to
   watch it during development). Set it as the active theme.

See `plugin/README.md` and `theme/README.md` for specifics.
