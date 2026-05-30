# second-brain — agent guide

A Discourse plugin that makes **Discourse the UI for a `term-llm` bot** ("stan") —
a private, invite-only knowledge base + AI workspace for a small family. Chats are
Discourse PMs with the bot; the bot streams answers, runs tools/web search, embeds
widgets, and can act on the forum (create topics, reply, search).

## Local development

Running the full thing locally (chat **and** forum actions) is scripted and
idempotent:

```bash
scripts/setup-local-dev.sh        # set up / repair; --new-key to rotate the bot key
```

There's a Claude Code skill (`.claude/skills/local-dev-setup/`) that wraps this —
use it when asked to "set up local dev", "connect stan", or "get the bot acting on
the forum". The one step the script can't do is a `sudo ufw` rule (it prints it for
the user). Full explanation + troubleshooting: `docs/local-dev.md`.

## Layout

- `plugin.rb`, `lib/second_brain/` — bot wiring, term-llm HTTP client, streaming,
  tool-call rendering, forum-context injection.
- `app/`, `assets/` — controllers/jobs and the Discourse-side JS/SCSS (chat UI,
  inline reply box, widget proxy + sidebar, streaming).
- `term-llm/` — the **bot side**: the `discourse` skill the bot uses to act on the
  forum, plus its own README (remote/droplet deploy).
- `config/`, `db/` — settings and install-time setting migrations.

## Conventions

- Ruby changes (plugin.rb, controllers, settings, jobs) need a **full Rails
  restart**; JS/SCSS hot-reload.
- Lint before committing: `cd ~/discourse && bin/lint --fix <files>` (the `.gjs`
  parser only resolves from inside the Discourse checkout via the symlinked path).
- Commit only when the user asks.
