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
                         │   widget iframe ─► GET /second-brain/widgets/* (reverse proxy w/ token)│               │
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
   into Discourse's native PM view.
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
- **Client** (`api-initializers/second-brain-stream.js`) subscribes and updates the
  **post model's `cooked`** via the topic post stream
  (`controller:topic` → `postStream.findLoadedPost(id).set("cooked", html)`). Setting
  DOM `innerHTML` directly does not work — Ember reverts it.
- **Finalize.** The answer is persisted once (`update_columns(raw)` + `rebake!`) and a
  single `publish_change_to_clients!(:revised)` lets non-streaming viewers catch up.

Tool calls are rendered as a collapsible `[details]` block above the answer; each tool
shows an icon + name + status + its essential args (a denylist hides noisy args;
long/multi-line values go in safely-fenced code blocks).

## B. Widgets (reverse proxy)

term-llm serves widget pages at `{base}/widgets/<name>/`. The browser can't reach
them directly (cross-site, needs term-llm's Bearer token), so:

- `BotResponder#proxy_widget_links` rewrites widget links to a same-origin path
  `/second-brain/widgets/<name>/`.
- `widgets_controller#show` reverse-proxies that to term-llm, **injecting the Bearer
  token server-side**, following redirects **only on the term-llm host** (SSRF guard),
  and setting its own permissive CSP header (Discourse's CSP middleware skips responses
  that already carry one; otherwise the widget's inline scripts are blocked).
- The client (`api-initializers/second-brain-widgets.js`) embeds proxied links as
  sandboxed iframes; a sidebar section (`…-widgets-sidebar.js`) lists widgets from
  `widgets_controller#index` (term-llm's `/admin/widgets/status`).

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
| `lib/second_brain/bot_responder.rb` | Core: guards, transcript, streaming, tool rendering, auto-title, widget-link rewrite, forum context |
| `lib/second_brain/term_llm_client.rb` | HTTP client to term-llm: `stream_respond` (agentic SSE), `respond`, `complete` (titling), SSE parsing |
| `app/controllers/second_brain/chats_controller.rb` | `create` (start a chat PM), `make_public` (convert PM → public topic) |
| `app/controllers/second_brain/widgets_controller.rb` | Widget reverse proxy (`#show`) + listing (`#index`) |
| `app/jobs/regular/second_brain_reply.rb` | Runs `respond!` off-request; swallows errors (no retry storm) |
| `assets/javascripts/.../second-brain-stream.js` | Paints streamed cooked HTML onto the post model |
| `assets/javascripts/.../second-brain-widgets*.js` | Iframe decorator + widgets sidebar |
| `assets/javascripts/.../second-brain-make-public.js` | "Make public" topic footer button |
| `assets/javascripts/.../components/launcher.gjs` | Homepage "message stan" launcher |
| `assets/javascripts/.../connectors/topic-area-bottom/second-brain-chat-reply.gjs` | Inline chat reply box |
| `assets/stylesheets/common/second-brain.scss` | Chat/homepage styling, forum-chrome trimming |
| `config/settings.yml` | Site settings (term-llm URL/token/model, bot username, categories, feature flags) |
| `db/migrate/*` | Install-time calm defaults via `INSERT … ON CONFLICT DO NOTHING` |
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

- **Symlinked plugin → manual require.** Discourse doesn't autoload a symlinked
  plugin's `app/` dirs, so controllers/jobs are `require_relative`'d in
  `after_initialize`. (Idiomatic long-term fix: the Rails **Engine** pattern.)
- **Ruby vs assets reload.** Ruby changes (plugin.rb, controllers, settings, jobs)
  need a full Rails restart; JS/SCSS hot-reload.
- **Secret stays server-side.** The term-llm Bearer token is a `secret` setting, used
  only by server-side code (the proxy + the chat client over MessageBus).
- **term-llm is remote & may be down.** All calls have timeouts; the reply job
  swallows errors so a failure never causes a retry storm or breaks the forum.
- **Custom homepage** via the core `:custom_homepage_enabled` modifier rendering the
  `custom-homepage` plugin outlet (not a theme, not the Blocks API).
- **Calm defaults, never clobbered.** Setting migrations seed defaults only if unset
  (`ON CONFLICT DO NOTHING`), so they never override an admin's later choices.
