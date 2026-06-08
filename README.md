# Second Brain

A Discourse plugin that turns Discourse into the **private UI for a [term-llm](https://term-llm.com)
AI assistant** ("stan") — a calm, invite-only knowledge base + AI workspace for a
small group (e.g. a family of ~5). You chat with the assistant from inside
Discourse; chats are **private by default** and can be shared with the family later.

term-llm is the brain (answers, web search, agentic tools, widgets); Discourse is
its face, its private container, and the knowledge base it can act on.

## What you get

- **A calm AI homepage** — a "Message stan…" launcher with starter prompts, with the
  forum chrome stripped away and a modern signature look.
- **Streaming chat** — each chat is a Discourse PM with the bot; replies stream in
  with a self-narrating "Searching the web…" indicator and a collapsible tool-call
  summary. Web search and agentic tools fire.
- **Interactive questions** — the bot can pause mid-answer to ask you structured
  questions (term-llm's `ask_user`), rendered as an inline form; you answer and it
  resumes. See [docs/ask-user.md](docs/ask-user.md).
- **Widgets** — term-llm's interactive widget pages, embedded inline as
  authenticated iframes and listed in a sidebar (via a same-origin reverse proxy
  that keeps the token server-side).
- **Forum actions** — the bot can act on the forum (create topics, reply, search)
  via a term-llm skill.
- **Make public** — turn a private chat into a topic the family can see.
- **Multi-agent** — each member can have their own private (TL4, owner-only)
  personal agent backed by its own term-llm container; the homepage launcher shows
  an agent switcher and remembers your last pick.

## Architecture (one paragraph)

Two independent directions: **Discourse → term-llm** (the plugin calls term-llm's
agentic HTTP API and streams the reply into a post) and **term-llm → Discourse**
(widget pages are reverse-proxied in; the bot calls Discourse's REST API to act on
the forum). Full detail in **[docs/architecture.md](docs/architecture.md)**.

---

## Recreate this setup on a dev box

The end state: Discourse dev server on `localhost:3000` with this plugin, talking
to a local term-llm "stan" container. The wiring is scripted — the detailed,
explained version is **[docs/local-dev.md](docs/local-dev.md)**; this is the
fast path.

### 0. Prerequisites

- **A Discourse dev environment.** Follow Discourse's official
  [dev setup](https://meta.discourse.org/t/install-discourse-for-development-using-docker/102009);
  you should be able to run `cd ~/discourse && bin/dev` and load `localhost:3000`.
- **term-llm installed** and a **"stan" container running**:
  ```bash
  # install term-llm (see https://term-llm.com), then:
  term-llm contain new stan        # create the workspace
  term-llm contain start stan      # start it → container term-llm-contain-stan-app-1
  docker ps | grep stan            # confirm it's up (serves :8081)
  ```
- **Docker usable without sudo** (you're in the `docker` group). **python3** on the
  host is needed for the dev forwarder on **Linux only**; macOS (Docker Desktop) uses
  `host.docker.internal` instead and needs neither the forwarder nor `ufw`.

### 1. Get the plugin

```bash
git clone <this-repo> ~/work/second-brain
ln -s ~/work/second-brain ~/discourse/plugins/second-brain
```
(The plugin is run **symlinked**. Note: this means Discourse won't autoload its
`app/` dirs — handled by `require_relative` in `plugin.rb`. Ruby changes need a full
`bin/dev` restart; JS/SCSS hot-reload.)

### 2. Wire it up (one command)

```bash
cd ~/work/second-brain && scripts/setup-local-dev.sh          # agent "stan" (default)
cd ~/work/second-brain && scripts/setup-local-dev.sh john     # a differently-named agent
cd ~/work/second-brain && scripts/setup-local-dev.sh stan-arpit --owner arpit  # a personal agent for one member (TL4, private)
```
The agent name is an argument (defaults to `stan`) and drives both the container it
talks to and the Discourse bot username, so nothing is pinned to one name.
A personal agent needs a `bin/dev` restart to pick up its new DB row.
This discovers the agent's container + docker network, points the plugin at local stan,
makes the bot an admin with a Discourse API key, installs the `discourse` skill +
credentials into stan, seeds the calm forum layout (`rake second_brain:setup`), wires
the container→host path, and verifies the round-trip.
(Installing the plugin by hand instead? Run the calm-layout seeding once yourself:
`cd ~/discourse && bin/rake second_brain:setup` — it's idempotent and only touches
settings still at their factory default.)
The script is **OS-aware**: on Linux it starts the host forwarder and **prints one
`sudo ufw` line** it can't run itself — a broad docker-range rule
(`sudo ufw allow from 172.16.0.0/12 to any port 3000`), broad because each agent
gets a new docker subnet so this covers current + future agents (run that, then
re-run the script); on macOS it uses `host.docker.internal` and skips both. See
[docs/local-dev.md](docs/local-dev.md) for what each step does.

### 3. Let questions wait for a human (recommended)

So a paused `ask_user` survives async answering (default is 30 min), give stan a
longer response timeout — add `response_timeout: 24h` under `serve:` in the
container's `~/.config/term-llm/config.yaml` and `term-llm contain restart stan`.
(docs/local-dev.md covers this in detail.)

### 4. Restart Discourse and open it

```bash
cd ~/discourse && bin/dev    # picks up the Ruby/plugin changes
```
Open `localhost:3000`, type a message to stan, and you're in. Try a planning/research
prompt to see the interactive question form.

> **Remote (DO droplet / prod) stan?** Same plugin steps; only the network path
> differs — instead of the host forwarder, expose Discourse publicly (e.g. a
> Cloudflare tunnel) so the remote stan can reach it. See the "Remote variant" in
> docs/local-dev.md.

---

## Configuration (Admin → Settings → Plugins)

| Setting | Notes |
|---|---|
| `second_brain_term_llm_url` | term-llm base URL incl. base path, e.g. `http://localhost:8081/chat` |
| `second_brain_term_llm_api_key` | Bearer token (`WEB_TOKEN`) — server-side only, never sent to the browser |
| `second_brain_term_llm_model` | Optional; blank = term-llm's default |
| `second_brain_stream_idle_timeout` | Abort a streaming reply after this many seconds of silence from term-llm, freeing the worker (default 300). Keep it above the longest a single tool runs silently. |
| `second_brain_bot_username` | The assistant's account username (default `stan`) |
| `second_brain_public_category` | Category "Make public" posts into; blank = auto-pick |
| `second_brain_forum_actions_enabled` | Let the bot act on the forum (needs the `discourse` skill + creds on stan) |

`scripts/setup-local-dev.sh` sets the first two and the forum-actions flag for you.

### Going private (before inviting real family)

Two one-shot rake tasks (auto-loaded by Discourse):

```bash
cd ~/discourse
bin/rake second_brain:setup      # calm layout — idempotent, only touches factory-default settings
bin/rake second_brain:lockdown   # login_required + invite_only + no search indexing
```

`setup` runs automatically via `setup-local-dev.sh`; `lockdown` is deliberate
(run it knowingly) — it prints the before → after for each setting and is easy to
revert. Without it the forum is publicly reachable and search-indexed.

### Agents on a live server

`setup-local-dev.sh` is dev-only (it discovers a *local* docker container). When the
term-llm agent runs anywhere else (a droplet, a hosted box), you wire it up with
rake tasks instead — they're location-agnostic about term-llm (they just store the
URL + token) and run wherever Discourse runs. Secrets go via **env vars** so an odd
character in a token won't break shell splitting.

> **Invocation:** a dev checkout uses `bin/rake …`; **inside a production Discourse
> Docker container** (`cd /var/discourse && ./launcher enter app`, then
> `cd /var/www/discourse`) use plain **`rake …`** — `bin/rake` fails there. The
> examples below use `rake`.

**Family agent** — endpoint **+ the bot's forum-action key** (one command vs editing settings):
```bash
SB_URL=https://stan.example.com/chat SB_TOKEN=<web-token> \
  rake second_brain:set_family_agent       # optional: SB_MODEL=gpt-5.5  SB_NEW_KEY=1
```

**Personal agents** — register/list/remove (admin-run; idempotent):
```bash
SB_BOT=jarvis SB_OWNER=arpit SB_URL=https://jarvis.example.com/chat SB_TOKEN=<web-token> \
  rake second_brain:add_agent              # optional: SB_MODEL=gpt-5.5  SB_NEW_KEY=1
rake second_brain:list_agents              # all agents (tokens masked)
SB_BOT=jarvis SB_DEACTIVATE=1 rake second_brain:remove_agent
```

Both `set_family_agent` and `add_agent` set up **both directions** and print exactly
what to do next:
- **Chat** (Discourse → term-llm): the `SB_URL` + `SB_TOKEN` you pass.
- **Forum actions** (term-llm → Discourse): they ensure the bot user (family = admin,
  personal = TL4), mint + **print once** a Discourse API key, and print the
  `DISCOURSE_URL` / `DISCOURSE_BOT_USERNAME` / `DISCOURSE_API_KEY` to set on the bot's
  term-llm host — **plus a pointer to [term-llm/README.md](term-llm/README.md)** for
  installing the `discourse` skill there. Live immediately — no restart.

> When **both** Discourse and term-llm are public, forum actions need **no tunnel** —
> set the term-llm host's `DISCOURSE_URL` to your site URL + the printed key. (The
> `cloudflared` tunnel is only for exposing a *local* Discourse; see
> [docs/local-dev.md](docs/local-dev.md) "Remote variant".)

## Documentation

| Doc | What |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How it works — the two directions, streaming, components |
| [docs/local-dev.md](docs/local-dev.md) | Detailed, explained local setup + troubleshooting |
| [docs/ask-user.md](docs/ask-user.md) | The interactive-questions protocol + design |
| [CLAUDE.md](CLAUDE.md) | Repo orientation for coding agents |
| [.claude/skills/local-dev-setup/](.claude/skills/local-dev-setup/SKILL.md) | Agent skill that runs the local setup |

## Working notes

- **Ruby changes** (`plugin.rb`, controllers, jobs, settings) need a full `bin/dev`
  restart; **JS/SCSS hot-reload**.
- Tests live in `spec/` (RSpec request + lib specs); run from the Discourse
  checkout, e.g. `cd ~/discourse && bin/rspec plugins/second-brain/spec`.
- Lint before committing: `cd ~/discourse && bin/lint --fix <files>`. The `.gjs`
  parser only resolves from inside the Discourse checkout (via the symlinked path).
- The term-llm Bearer token and the bot's Discourse admin key are **secrets** — they
  live server-side / in stan's environment, never in the browser or in committed files.
