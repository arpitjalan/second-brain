# Second Brain

Turns Discourse into a personal knowledge organizer — a calm, Notion-flavored
"second brain" rather than a public community. A **note** is a Discourse topic;
replies are sub-thoughts / annotations.

**One plugin, no separate theme.** The plugin takes over the homepage itself
(via the `custom_homepage_enabled` modifier), renders it with a plain component
tree behind the `custom-homepage` plugin outlet, ships its own CSS, and holds
the backend "brain" (term-llm, to come).

## How the homepage works

```
plugin.rb
  register_modifier(:custom_homepage_enabled) { true }   # HomepageHelper → "custom" route
                                                          # → discovery/custom renders the
                                                          #   custom-homepage plugin outlet
assets/javascripts/discourse/
  connectors/custom-homepage/second-brain-home.gjs   the homepage: <Capture/><RecentNotes/>
  components/capture.gjs        opens the composer (first line → note title)
  components/recent-notes.gjs   latest topics as cards (store.findFiltered)
assets/stylesheets/common/second-brain.scss   Notion-calm BEM styling (.sb-home)
```

`custom_homepage_enabled` is a **plugin** modifier (`DiscoursePluginRegistry`),
so a plugin can own the homepage with no theme — confirmed in core
`lib/homepage_helper.rb`. We deliberately use the stable `custom-homepage`
plugin-outlet approach rather than the `@experimental` Blocks API; the Blocks
spike is preserved on the `blocks-homepage` branch.

## Setting defaults — applied automatically on install

A migration (`db/migrate/…_configure_second_brain_defaults.rb`) seeds calm
global settings via `INSERT … ON CONFLICT (name) DO NOTHING`, so a fresh site
gets them for free and an existing site that already customized one keeps its
own value:

| Setting | Value | Why |
|---|---|---|
| `enable_chat` | `false` | Removes the CHANNELS sidebar section |
| `post_menu` | default minus `like` | Drops the Like button (read from the live default, version-safe) |
| `top_menu` | `latest` | Tidies the nav for the few non-home forum pages |

(The welcome banner and forum nav don't render on our custom homepage, so those
are no longer about the home screen.)

## Roadmap

- **M1 — Homepage (in progress).** Capture + recent-notes on a plugin-owned
  custom homepage via the stable `custom-homepage` plugin outlet.
- **M2 — term-llm sidecar.** Run [term-llm](https://term-llm.com) as a local
  HTTP service; on new note embed / auto-tag / summarize; add an `<AskBrain />`
  component doing RAG over your notes. Hook points in `plugin.rb` `after_initialize`.

## Install (dev)

Symlinked into a Discourse checkout at `plugins/second-brain`; it builds with
Discourse and `db:migrate` seeds the settings above. Enable
`second_brain_enabled` and open the homepage.

> Display strings are hard-coded for now; make them translatable once the Blocks
> wiring is verified against a running instance.
