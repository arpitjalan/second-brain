# second-brain — agent guide

A Discourse plugin that makes **Discourse the UI for a `term-llm` bot** ("stan") —
a private, invite-only knowledge base + AI workspace for a small family. Chats are
Discourse PMs with the bot; the bot streams answers, runs tools/web search, embeds
widgets, can pause to ask **interactive questions** (`ask_user`), and can act on the
forum (create topics, reply, search). The homepage is a calm launcher + a board of
recent/shared chats, with a modern signature look.

Start here: **README.md**. Deeper docs: `docs/architecture.md` (how it works),
`docs/local-dev.md` (setup + troubleshooting), `docs/ask-user.md` (interactive
questions protocol).

## Local development

Running the full thing locally (chat **and** forum actions) is scripted and
idempotent:

```bash
scripts/setup-local-dev.sh        # set up / repair agent "stan" (the default)
scripts/setup-local-dev.sh john   # a differently-named agent; --new-key rotates the bot key
scripts/setup-local-dev.sh stan-arpit --owner arpit  # a PERSONAL agent (TL4, owner-private)
```

The agent name is the first argument (defaults to `stan`) and drives both the
container (`term-llm-contain-<agent>-app-1`) and the Discourse bot username — nothing
is hardcoded to one name. Passing `--owner USER` provisions a per-user TL4 agent
stored in the `second_brain_agents` registry (multiple agents per owner are
supported); the bare/family agent has no owner and falls back to global settings.

There's a Claude Code skill (`.claude/skills/local-dev-setup/`) that wraps this —
use it when asked to "set up local dev", "connect stan", or "get the bot acting on
the forum". The script is OS-aware (Linux: docker gateway + forwarder; macOS:
`host.docker.internal`). The one step it can't do is a `sudo ufw` rule on **Linux**
(it prints it for the user); macOS needs no such step. Full explanation +
troubleshooting: `docs/local-dev.md`.

## Layout

- `plugin.rb`, `lib/second_brain/` — bot wiring, term-llm HTTP client, streaming,
  tool-call rendering, forum-context injection, plus the `SecondBrain::Agent`
  abstraction (`agent.rb`) that resolves a chat/widget to its agent (family vs
  personal).
- `app/`, `assets/` — controllers/jobs (including the registry model
  `app/models/second_brain/agent_record.rb`) and the Discourse-side JS/SCSS (chat
  UI, inline reply box, widget proxy + sidebar, streaming). The widget proxy is
  agent-aware (`/second-brain/agent-widgets/<agent>/*path`, legacy
  `/second-brain/widgets/*path` kept for family).
- `term-llm/` — the **bot side**: the `discourse` skill the bot uses to act on the
  forum, plus its own README (remote/droplet deploy).
- `config/`, `db/`, `lib/tasks/` — settings; the `second_brain_agents` schema
  migration; `rake second_brain:setup` (idempotent calm-layout seeding —
  settings, not schema, so a rake task rather than a migration); and
  `rake second_brain:lockdown` (login-required + invite-only + no search indexing).

## Conventions

- Ruby changes (plugin.rb, controllers, settings, jobs) need a **full Rails
  restart**; JS/SCSS hot-reload.
- Lint before committing: `cd ~/discourse && bin/lint --fix <files>` (the `.gjs`
  parser only resolves from inside the Discourse checkout via the symlinked path).
- Tests: `cd ~/discourse && bin/rspec plugins/second-brain/spec` (plugin specs only
  resolve from inside the Discourse checkout).
- Commit only when the user asks.
