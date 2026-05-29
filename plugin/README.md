# Second Brain — plugin (backend "brain")

The backend half of [Second Brain](../README.md). The **homepage UI lives in the
companion `../theme`** (custom homepage + Blocks); this plugin handles
server-side concerns: calm global setting defaults today, and the term-llm
sidecar to come.

## Roadmap

- **M1 — Setting defaults (this milestone).** Seed the calm global settings
  below on install. (The homepage capture + notes UI is in the theme.)
- **M2 — term-llm sidecar.** Run [term-llm](https://term-llm.com) as a local
  HTTP service. On new note: embed + auto-tag + summarize. Surface an
  "ask my brain" RAG block on the homepage. See `plugin.rb` `after_initialize`.

## Layout

```
plugin.rb                                  metadata + setting registration; M2 hooks
config/settings.yml                        plugin site settings
config/locales/{client,server}.en.yml      strings
db/migrate/…_configure_second_brain_defaults.rb   seeds global setting defaults
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
