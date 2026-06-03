# Architecture

A high-level map of how the **second-brain** plugin works. For local setup see
[local-dev.md](local-dev.md); for repo orientation see [../CLAUDE.md](../CLAUDE.md).

## What it is

A Discourse plugin that makes **Discourse the UI for a `term-llm` AI bot** ("stan")
— a private, invite-only knowledge base + AI workspace for a small family. A *chat*
is a Discourse Personal Message (PM) between a member and the bot user. The bot
streams answers, runs tools / web search, embeds interactive widgets, and can act on
the forum.

term-llm is the brain and runs as a **separate HTTP service** (typically on another
host). Discourse is its face, its private container, and the knowledge base it acts on.

## The big picture

```
                         ┌─────────────────────────────── Discourse (this plugin) ───────────────────────────────┐
   Family member         │                                                                                       │
   (browser)             │   homepage launcher ─► POST /second-brain/chats ─► creates a PM with the bot user     │
       │ types a message │                                                                                       │
       ▼                 │   on(:post_created) ─► BotResponder.maybe_respond ─► enqueue Jobs::SecondBrainReply    │
   a PM post  ───────────┼─► (Sidekiq job)  BotResponder#respond!                                                 │
       ▲                 │        │  posts a "Thinking…" placeholder                                              │
       │ streamed reply  │        │  calls term-llm, streams cooked HTML over MessageBus  ◄───────┐               │
       └─────────────────┼────────┘                                                              │               │
                         │                                                                       │ A. chat (HTTP)│
                         │   widget iframe ─► GET /second-brain/widgets/* (family) or             │               │
                         │        /second-brain/agent-widgets/<agent>/* (personal); proxy injects │               │
                         │        that agent's token                                             │               │
                         └───────────────────────────────────────────────────────────────────────┼───────────────┘
                                                                                                  ▼
                                                                                         ┌──────────────────┐
                                                       B. forum actions (REST + admin key)│   term-llm       │
                                                       Discourse REST API ◄───────────────│   "stan" (HTTP)  │
                                                                                          │  /v1/responses   │
                                                                                          │  /chat/widgets/* │
                                                                                          └──────────────────┘
```

There are **two independent integration directions**, wired separately:

- **A — Discourse → term-llm (chat).** The plugin calls term-llm's agentic HTTP API
  and streams the answer into a post. This is the main path.
- **B — term-llm → Discourse (widgets + forum actions).** term-llm-served widget pages
  are reverse-proxied into Discourse; and the bot can call Discourse's REST API to act
  on the forum (create topics, reply, search).

## A. Chat request lifecycle

1. **Start.** The homepage launcher (`components/launcher.gjs`) POSTs to
   `/second-brain/chats` (`chats_controller#create`), which creates a PM between the
   member and the bot user (a throwaway title) and returns its URL; the client routes
   into Discourse's native PM view. `create` resolves **which agent** to chat with via
   `create_agent` — the member's personal agent, the family agent, or a named `agent`
   param (restricted to its owner). The launcher offers an **agent switcher**
   (persisted per-user in `localStorage`) when the member has more than the family
   agent.
2. **Trigger.** Any new PM post fires `on(:post_created)` →
   `BotResponder.maybe_respond` (`plugin.rb`). Cheap synchronous **guards** run
   (plugin enabled, regular post, it's a PM, term-llm configured, author isn't the
   bot — loop guard, bot is a participant), then it enqueues `Jobs::SecondBrainReply`.
3. **Reply (off-request).** The Sidekiq job runs `BotResponder#respond!`, which:
   - posts a `_Thinking…_` placeholder post immediately,
   - builds the transcript (`build_messages`) from the PM's posts, optionally prefixed
     with a **forum-context** system message (when forum actions are enabled),
   - calls `TermLlmClient#stream_respond` and **streams** the growing answer into the
     placeholder,
   - on completion, persists the final answer once and auto-titles the chat.
4. **Auto-title.** `maybe_title!` makes one quick non-agentic term-llm call to name the
   chat from the first message (guarded by a topic custom field so it runs once).

The user can also reply inline from the chat via the box in
`connectors/topic-area-bottom/second-brain-chat-reply.gjs` (posts via the API and
appends to the stream) instead of the native composer.

## Streaming design (the hard-won part)

Naively re-saving the post per token causes the browser to refetch it every tick (a
request storm). Instead:

- **Server** publishes partial **cooked HTML** to a dedicated MessageBus channel
  `/second-brain/stream`, scoped to the PM's participants (`user_ids:`), throttled
  (`STREAM_THROTTLE`) but flushed immediately on tool start/finish. No DB write per
  tick. (`BotResponder#publish_stream`.)
- **Client** (`api-initializers/second-brain-stream.js`) subscribes and **morphs the
  live `.cooked` DOM** via morphlex (`morphInner`) while streaming — like Discourse's
  own AI streamer — and `preventCloak`s the post so it stays rendered. It sets the
  **post model's `cooked`** only on the final message (and as a fallback when the post
  element isn't on screen).
- **Finalize.** The answer is persisted once (`update_columns(raw)` + `rebake!`) and a
  single `publish_change_to_clients!(:revised)` lets non-streaming viewers catch up.

Tool calls are rendered as a collapsible `[details]` block above the answer; each tool
shows an icon + name + status + its essential args (a denylist hides noisy args;
long/multi-line values go in safely-fenced code blocks).

## B. Widgets (reverse proxy)

term-llm serves widget pages at `{base}/widgets/<name>/`. The browser can't reach
them directly (cross-site, needs term-llm's Bearer token), so:

- `BotResponder#proxy_widget_links` rewrites widget links to a same-origin path:
  `/second-brain/widgets/<name>/` for the family agent, and
  `/second-brain/agent-widgets/<owner>/<name>/` for a personal agent.
- `widgets_controller#show` reverse-proxies that to term-llm, **injecting the Bearer
  token server-side**, following redirects **only on the term-llm host** (SSRF guard),
  and setting its own permissive CSP header (Discourse's CSP middleware skips responses
  that already carry one; otherwise the widget's inline scripts are blocked). For a
  personal agent it also calls `#rewrite_widget_base` to rebind the widget's absolute
  HTML refs to its own agent-scoped prefix.
- The client (`api-initializers/second-brain-widgets.js`) embeds proxied links as
  sandboxed iframes; a sidebar section (`…-widgets-sidebar.js`) lists widgets from
  `widgets#index` at `GET /second-brain/list-widgets`, which aggregates each available
  agent's `/admin/widgets/status`.

**The term-llm Bearer token never reaches the browser** — it's a secret site setting
used only server-side by the proxy and the chat client.

## B. Forum actions

When `second_brain_forum_actions_enabled` is on, `BotResponder#forum_context` prepends
a system message telling the bot it's in the forum and can act via its `discourse`
skill. On the term-llm side, that skill (`term-llm/skills/discourse/SKILL.md`) calls
Discourse's REST API with an **admin API key** scoped to the bot account — the bot
always acts as **itself**, never impersonating members. The key lives in term-llm's
environment, never in the skill file or the conversation.

## Component reference

| File | Responsibility |
|---|---|
| `plugin.rb` | Wiring: custom-homepage modifier, `post_created` hook, route registration, `require_relative` of app/ classes |
| `lib/second_brain/bot.rb` | Find/create the bot user from `second_brain_bot_username` |
| `lib/second_brain/bot_responder.rb` | Core: guards, turn claim, transcript, streaming (per-turn session id + a heartbeat that keeps `updated_at` fresh), tool rendering, auto-title, ask_user pause/`resume!`, `abort_with_failure!` (surface unexpected errors), `reconcile_stranded!` (watchdog), `supersede_pending_question!`, widget-link rewrite, forum context |
| `lib/second_brain/term_llm_client.rb` | HTTP client to term-llm: `stream_respond` (agentic SSE), `stream_events` (resume reconnect), `submit_ask_user`, `respond`, `complete` (titling), SSE parsing; the streaming `read_timeout` is the configurable `second_brain_stream_idle_timeout` (idle timeout) |
| `app/controllers/second_brain/chats_controller.rb` | `create` (start a chat PM, agent-aware), `make_public` (convert PM → public topic), `agents` (list agents for the switcher), `home` (homepage board), `answer` (resume an `ask_user` run) |
| `app/controllers/second_brain/widgets_controller.rb` | Widget reverse proxy (`#show`) + listing (`#index`) |
| `lib/second_brain/agent.rb` | `SecondBrain::Agent` abstraction — family + personal agents, resolution, per-agent client/token/model |
| `app/models/second_brain/agent_record.rb` | `second_brain_agents` registry model |
| `app/jobs/regular/second_brain_reply.rb` | Runs `respond!`/`resume!` off-request; on an unexpected error surfaces a failure on the post via `abort_with_failure!` + logs a greppable tag, but never re-raises (no retry storm) |
| `app/jobs/scheduled/second_brain_watchdog.rb` | Periodic backstop (every 5m): finalizes turns stranded by a hard worker kill (still on "Thinking…", or answered-but-unfinalized) past a derived cutoff, via `BotResponder#reconcile_stranded!` — **never calls term-llm** |
| `assets/javascripts/.../second-brain-stream.js` | Streams cooked HTML into the post by morphing the live `.cooked` DOM (morphlex) |
| `assets/javascripts/.../second-brain-widgets*.js` | Iframe decorator + widgets sidebar |
| `assets/javascripts/.../second-brain-make-public.js` | "Make public" topic footer button |
| `assets/javascripts/.../components/launcher.gjs` | Homepage "message stan" launcher |
| `assets/javascripts/.../connectors/topic-area-bottom/second-brain-chat-reply.gjs` | Inline chat reply box |
| `assets/stylesheets/common/second-brain.scss` | Chat/homepage styling, forum-chrome trimming |
| `config/settings.yml` | Site settings (term-llm URL/token/model, bot username, categories, feature flags) |
| `lib/tasks/second_brain.rake` | `rake second_brain:setup` (calm-layout seeding) + `:lockdown` (login_required/invite_only/noindex) |
| `db/migrate/*` | Real schema only (the `second_brain_agents` registry table) |
| `term-llm/skills/discourse/SKILL.md` | The bot-side skill for forum actions |

## External interfaces

- **term-llm HTTP API** (consumed by the plugin): `POST /v1/responses` (agentic,
  `include_server_tools`, streaming SSE — `response.output_text.delta`,
  `response.tool_exec.start/.end`, `[DONE]`), `POST /v1/chat/completions` (titling),
  `/admin/widgets/status`, `/widgets/*`. Auth: `Authorization: Bearer <token>`.
- **Discourse REST API** (consumed by the bot via the skill): `POST /posts.json`
  (topic/reply/PM), `GET /search.json`, `/categories.json`, `/session/current.json`.
  Auth: `Api-Key` + `Api-Username` (the bot).

## Cross-cutting design decisions & constraints

- **Agent model.** One shared **family agent** (legacy routes/widgets) plus optional
  **per-user personal agents** (owner-private, TL4), each with its own bot user, token,
  model, and agent-scoped widget proxy; all resolved via `SecondBrain::Agent`. The
  plugin now has request/unit specs under `spec/`.
- **Symlinked plugin → manual require.** Discourse doesn't autoload a symlinked
  plugin's `app/` dirs, so controllers/jobs are `require_relative`'d in
  `after_initialize`. (Idiomatic long-term fix: the Rails **Engine** pattern.)
- **Ruby vs assets reload.** Ruby changes (plugin.rb, controllers, settings, jobs)
  need a full Rails restart; JS/SCSS hot-reload.
- **Secret stays server-side.** The term-llm Bearer token is a `secret` setting, used
  only by server-side code (the proxy + the chat client over MessageBus).
- **term-llm is remote & may be down.** All calls have timeouts, and a streaming
  reply also aborts after `second_brain_stream_idle_timeout` of silence. The reply
  job never re-raises (no Sidekiq retry storm), and failures are *surfaced on the
  post* rather than left as a stuck "Thinking…" placeholder: a `TermLlmClient::Error`
  → `reply_failed`, an unexpected error → `abort_with_failure!`, and a turn killed
  mid-flight (OOM/deploy) → reconciled by the watchdog.
- **Custom homepage** via the core `:custom_homepage_enabled` modifier rendering the
  `custom-homepage` plugin outlet (not a theme, not the Blocks API).
- **Calm defaults, never clobbered.** `rake second_brain:setup` seeds the calm
  layout (welcome banner off, top menu collapsed, chat off, reactions on) only if a
  setting is still at its factory default (`ON CONFLICT DO NOTHING`), so it never
  overrides an admin's later choices. It's a rake task, not a migration — seeding
  *settings* isn't a schema change and shouldn't ride `db:migrate`. `db/migrate/`
  is reserved for real schema (the `second_brain_agents` registry table).
  `scripts/setup-local-dev.sh` runs the task for you in local dev.
