# Design: family agent + per-user agents

Status: **shipped — merged to `main`.** Phase 1 (behaviour-neutral Agent
abstraction) and Phase 2 (registry, per-user agents, routing, access control,
launcher switcher, agent-aware widgets, provisioning) are both in. Verified by
RSpec — 23 examples across `spec/lib/second_brain/agent_spec.rb`,
`spec/requests/second_brain/chats_controller_spec.rb`, and
`spec/requests/second_brain/widgets_controller_spec.rb`.
To actually run a personal agent, provision one (see `docs/local-dev.md` →
"Add a personal agent"). Companion to `docs/architecture.md`.

## Goal

Today one term-llm agent ("stan") talks to everyone. We want:

- **A shared family agent** (`stan`) — the default, forum-aware assistant that
  knows the family KB and acts on it (admin). This is what exists today.
- **Optional per-user personal agents** (`stan-arpit`, …) — each its own private
  assistant with its own memory, opt-in per person.

## Decisions (locked)

| Question | Decision |
|---|---|
| Compute model | **One term-llm container per agent** (separate serve/memory). |
| Identity | **Distinct named bots** — each agent is its own Discourse user. |
| Config | An **agent registry**; the plugin becomes agent-aware. |
| Rollout | Ships running **family stan only** (behaves exactly like today). Personal agents are opt-in provisioning, no new code to add one. |
| Forum power (personal) | Personal agents are **TL4 (non-admin) users** — full create/reply/post on the forum, with their **own user-scoped (non-admin) API key**. (Per-agent dial; admin can come later.) |
| Privacy (personal) | **Private to owner** — only the owner may message their personal agent. |
| Launcher | Defaults to **your** agent (else family stan), with a **switcher** to choose another. |
| Naming | The **owner names their agent** (free choice). That name = its Discourse bot username **and** its term-llm `--agent` name. |
| Persona / model | **Per agent** — each agent picks its own model + system prompt in its term-llm `agents/<name>/` config. The plugin stops forcing a global model; an agent uses its own default (optional per-agent override in the registry). |
| Widgets | The sidebar shows **both** family + the user's personal widgets (agent-labeled). The widget proxy is **agent-aware + access-controlled**. |

## The constraint that shapes this (from term-llm)

- **One `serve` instance = one agent**, bound at startup (`serve web --agent X`).
  No per-request agent selection on `/v1/responses`. So *a distinct agent is a
  distinct container.* (Multiplexing agents on one serve would need a term-llm
  change — out of scope; noted as a future optimization.)
- **Memory is per-container** (per-session by `session_id`, persistent memory is
  agent-scoped). Separate containers therefore give clean per-agent memory
  isolation for free.

This is *why* distinct-bots-per-container is both the clearest UX and the
simplest code: **the bot you're PMing IS the agent** — no owner-guessing, no
group-chat edge cases, no muddied identity.

## Architecture

### An "agent" is

```
Agent = {
  bot_user        : the Discourse User the chat is with (stan, stan-arpit)
  term_llm_url    : that agent's serve endpoint  (e.g. http://localhost:8082/chat)
  term_llm_token  : that serve's WEB_TOKEN        (server-side secret, never sent to client)
  agent_name?     : optional term-llm --agent name (usually == bot username)
  owner_user_id?  : null = shared/family; set = personal (private to that user)
  forum_role      : :admin (family) | :tl4 (personal) | :none
  model?          : optional per-agent model override (else the agent's own default)
}
```

The owner picks the `bot_user`/`agent_name` (free-form name). Model + persona
live in that agent's term-llm config (`agents/<name>/agent.yaml` + `system.md`),
so each personal agent can be a different model/personality — set at provisioning.

### Registry

- Source of truth: a small table (`second_brain_agents`) keyed by `bot_user_id`,
  holding the fields above. Tokens live in a server-side column, **never
  serialized to the client** (same rule as today's `secret: true` setting).
- **Backward-compatible:** the **family/default agent needs no row** —
  `Agent.resolve(bot_user)` falls back to today's global settings
  (`second_brain_term_llm_url` / `_api_key` / `_bot_username`) when there's no
  registry row. So with zero rows, behavior == today. Personal agents add rows.

### Routing (the simple part)

- `maybe_respond` matches **any registered agent bot** in the PM (not just the
  one `Bot.user`), resolves its `Agent`, and the reply job uses **that agent's**
  endpoint + token.
- `session_id` stays `sb_<topic_id>` — already unique per chat, and per-agent
  endpoints make memory naturally isolated.

### Access control (personal agents)

- `chats_controller#create` and `maybe_respond`: if the target/recipient agent
  has an `owner_user_id`, **refuse** unless `current_user == owner` (create) and
  the topic's human participant is the owner (reply). Family agents (no owner)
  are open to everyone.

### Launcher UX

- The homepage "Message…" box targets the current user's **personal agent if
  they have one, else family stan**.
- A small **switcher** lists the agents this user may talk to (family stan +
  their own personal agent). `chats_controller#create` takes an explicit
  `agent` (bot username) param; default resolved server-side.
- The switcher **remembers your last-picked agent in `localStorage`** (keyed per
  user), so it reopens to that agent instead of the server-resolved default.
- `#home` "recent chats" matches **any agent bot** the user has chatted with.

### Widgets (agent-aware)

Widgets live in each agent's own container, so the widget layer mirrors the chat
routing:

- **Sidebar shows both** — `WidgetsController#index` aggregates `/admin/widgets/
  status` across the agents the user can access (family + their own personal
  agent), tagging each entry with its agent; the sidebar groups them
  ("Family" / "Yours").
- **Agent-aware proxy** — a personal agent's proxy path encodes the agent
  (`/second-brain/agent-widgets/<agent>/<path>`); `#show` resolves that agent's
  `term_llm_url` + token from the registry and proxies there. The legacy
  `/second-brain/widgets/<path>` (no agent segment) is the **family** route, kept
  so old embeds keep working. The redirect-origin SSRF guard is then per-agent.
- **Agent-bound links** — `WidgetsController#rewrite_widget_base` rewrites a
  personal widget's absolute HTML widget-base refs back to its own agent-scoped
  prefix, so hardcoded absolute links stay bound to that agent (JS-constructed
  URLs are out of scope — see `docs/TODO.md`).
- **Access-controlled** — `#index`/`#show` only expose agents the user may use
  (family + their own), so a user never sees or loads another person's personal
  widgets.

## Forum power for personal agents (TL4)

- The personal agent's Discourse user is **TL4, not admin**. Its forum actions
  (via the `discourse` skill) use a **user-scoped API key** for that TL4 user —
  so it can create topics/posts/replies as itself, but **cannot do admin things**
  (impersonate, change settings, read others' PMs). This is a *stronger* posture
  than family stan's admin key.
- Knowledge boundary falls out of this: a TL4 agent can **read public/shared
  forum content** (the family KB) but its **term-llm memory is its own** (separate
  container) — private to its owner.

## Provisioning

`scripts/setup-local-dev.sh <agent> --owner <user>` provisions a personal agent
(TL4, owner-private, with its own registry row). It:

1. `term-llm contain new <agent>` + serves it on its **own host port** (stan→8081,
   stan-arpit→8082, …); the registry stores that per-agent URL.
2. Makes the bot user **TL4 (not admin)** and mints a **user-scoped API key** (not
   an admin key) for its forum actions.
3. Inserts/updates the **registry row** (`bot_user_id`, url, token, `owner_user_id`,
   `forum_role: :tl4`).
4. Bakes the agent's forum creds into its container env (as today).

It also runs `db:migrate` + `rake second_brain:setup` and recommends a
`sudo ufw allow from 172.16.0.0/12 to any port 3000` rule on Linux. So adding a
personal agent = run the script with `--owner <username>`; **no plugin code
change.**

**On a live server** (no local docker), the Discourse half is done by rake tasks
in `lib/tasks/second_brain.rake` — `second_brain:add_agent` (ENV: `SB_BOT`,
`SB_OWNER`, `SB_URL`, `SB_TOKEN`, optional `SB_MODEL`/`SB_NEW_KEY`),
`second_brain:list_agents`, `second_brain:remove_agent`. `add_agent` does steps
2–3 above (TL4 bot user, user-scoped API key it prints once, registry row) and
leaves the term-llm `serve` + its `DISCOURSE_API_KEY` env to the operator. The
registry row is live immediately (no restart). An admin UI for this is the open
Phase-3 polish.

## Change surface (sized from the code)

Phase-1 refactor (behavior-neutral, one agent == today) — **shipped:**

- `lib/second_brain/bot.rb` — `Bot.user` (one global) → `Agent.resolve(bot_user|topic)`.
- New `lib/second_brain/agent.rb` + the registry table/model.
- `lib/second_brain/term_llm_client.rb` — `TermLlmClient.new` → `TermLlmClient.new(agent)` (per-agent url/token; stop forcing the global model).
- `lib/second_brain/bot_responder.rb` — `maybe_respond` / `respond!` / `ensure_placeholder` / `build_messages` use the chat's `Agent`, not the single `Bot.user`.
- `app/controllers/second_brain/chats_controller.rb` — `#create` targets the resolved agent + access check; `#home` matches any agent bot.
- `app/controllers/second_brain/widgets_controller.rb` — `#index`/`#show` resolve the agent (from an `<agent>` path segment) and use its url/token; access-check the agent. (One agent == today.)

Phase-2 (personal agents) — **shipped:**

- `scripts/setup-local-dev.sh` — `--owner`, TL4 + user-scoped key, registry insert.
- Launcher switcher + `agent` param; owner-privacy enforcement.
- `…/api-initializers/second-brain-widgets-sidebar.js` — list widgets grouped by agent (Family / Yours), agent-scoped iframe srcs.

## Phased plan

1. **Agent-registry refactor** *(shipped)* — generalize the single-bot wiring
   behind `Agent`, seeded by the existing settings as the default/family agent.
   **Zero behavior change** with one agent. (The safe, mergeable first step.)
2. **Provisioning + access control + launcher switcher** *(shipped)* — make
   personal agents a config/ops step.
3. **Polish (open)** — a small admin UI for the registry; revisit the term-llm
   "one serve, many agents" optimization only if container count ever bites.

## Open / deferred

- **term-llm agent multiplexing** (one serve hosting many agents) — would remove
  the container-per-user cost, but needs a term-llm change (`agent_name` on
  `/v1/responses`). Revisit only if N containers becomes a real burden.
- **Token storage** — server-side column, never serialized; consider encrypting
  at rest if the DB is ever shared.
- **Cross-agent / group chats** — a PM with multiple humans routes to the family
  agent (personal agents are 1:1 with their owner).
- Admin-only provisioning for now (family scale); self-serve is a later question.
