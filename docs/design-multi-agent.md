# Design: family agent + per-user agents

Status: **agreed plan, not yet built.** This is the firm design we lock before
writing code. Companion to `docs/architecture.md`.

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
}
```

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
- `#home` "recent chats" matches **any agent bot** the user has chatted with.

## Forum power for personal agents (TL4)

- The personal agent's Discourse user is **TL4, not admin**. Its forum actions
  (via the `discourse` skill) use a **user-scoped API key** for that TL4 user —
  so it can create topics/posts/replies as itself, but **cannot do admin things**
  (impersonate, change settings, read others' PMs). This is a *stronger* posture
  than family stan's admin key.
- Knowledge boundary falls out of this: a TL4 agent can **read public/shared
  forum content** (the family KB) but its **term-llm memory is its own** (separate
  container) — private to its owner.

## Provisioning (already half-built)

`scripts/setup-local-dev.sh <agent>` is already agent-parameterized (spins up the
container + a Discourse bot user). For personal agents, extend it to:

1. `term-llm contain new <agent>` + serve it on its **own host port** (stan→8081,
   stan-arpit→8082, …); the registry stores that per-agent URL.
2. Make the bot user **TL4 (not admin)** and mint a **user-scoped API key** (not
   an admin key) for its forum actions.
3. Insert/update the **registry row** (`bot_user_id`, url, token, `owner_user_id`,
   `forum_role: :tl4`).
4. Bake the agent's forum creds into its container env (as today).

So adding a personal agent = run the script with `--owner <username>`; **no
plugin code change.**

## Change surface (sized from the code)

Phase-1 refactor (behavior-neutral, one agent == today):

- `lib/second_brain/bot.rb` — `Bot.user` (one global) → `Agent.resolve(bot_user|topic)`.
- New `lib/second_brain/agent.rb` + the registry table/model.
- `lib/second_brain/term_llm_client.rb` — `TermLlmClient.new` → `TermLlmClient.new(agent)` (per-agent url/token).
- `lib/second_brain/bot_responder.rb` — `maybe_respond` / `respond!` / `ensure_placeholder` / `build_messages` use the chat's `Agent`, not the single `Bot.user`.
- `app/controllers/second_brain/chats_controller.rb` — `#create` targets the resolved agent + access check; `#home` matches any agent bot.

Phase-2 (personal agents):

- `scripts/setup-local-dev.sh` — `--owner`, TL4 + user-scoped key, registry insert.
- Launcher switcher + `agent` param; owner-privacy enforcement.

## Phased plan

1. **Agent-registry refactor** — generalize the single-bot wiring behind `Agent`,
   seeded by the existing settings as the default/family agent. **Zero behavior
   change** with one agent. (The safe, mergeable first step.)
2. **Provisioning + access control + launcher switcher** — make personal agents a
   config/ops step.
3. **Polish (later)** — a small admin UI for the registry; revisit the term-llm
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
