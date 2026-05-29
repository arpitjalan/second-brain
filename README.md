# Second Brain

Makes Discourse the **private UI for [term-llm](https://term-llm.com)** for a
small group (e.g. a family of 5). You chat with the term-llm assistant from
inside Discourse; chats are **private by default** and can be made public later.

> **Branch note:** this `pm-chat` branch implements the chat-as-PM model below.
> `main` is the earlier single-page homepage chat. Milestone checkpoints:
> `checkpoint/m2-1-pm-chat`, `checkpoint/m2-2-launcher`, `checkpoint/m2-3-make-public`.

## How a chat works (PM-backed)

A **chat is a Personal Message** between a family member and a **bot user**
(`stan` by default). When a member posts in such a PM, the plugin calls term-llm
and the bot posts the reply. The conversation uses Discourse's **native message
UI** (history, search, mobile — all free); PMs are private by default.

```
plugin.rb
  register_modifier(:custom_homepage_enabled) { true }     # homepage = our launcher
  on(:post_created) { … BotResponder.maybe_respond(post) } # human posts in a bot PM → reply

lib/second_brain/
  term_llm_client.rb   server-side OpenAI-compatible client (Bearer; token never sent to browser)
  bot.rb               find/create the bot user
  bot_responder.rb     PM/loop guards, build transcript, post the reply
app/jobs/regular/second_brain_reply.rb     off-request term-llm call + reply post
app/controllers/second_brain/chats_controller.rb   POST …/chats/:id/make_public (PM → public topic)
assets/javascripts/discourse/
  connectors/custom-homepage/…   homepage launcher (Start a chat / Your chats)
  components/launcher.gjs        links to /new-message?username=<bot> and the PM inbox
  api-initializers/…make-public  "Make public" topic-footer button (owner/staff, bot PMs)
```

`custom_homepage_enabled` is a **plugin** modifier (`DiscoursePluginRegistry`),
so a plugin can own the homepage with no theme — confirmed in `lib/homepage_helper.rb`.
(The `@experimental` Blocks spike lives on the `blocks-homepage` branch.)

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

- **M1 — Homepage** (on `main`). Plugin-owned custom homepage.
- **M2 — Discourse as term-llm's UI.** Chat with term-llm from inside Discourse.
  - ✅ **PM-backed chat** (`pm-chat` branch): a chat is a PM with the bot; the bot
    replies via term-llm; private by default; **Make public** converts the PM to
    a topic. Server side verified end-to-end via rails runner.
  - **Next (not built — need runtime verification):** stream replies into the
    post (MessageBus + term-llm SSE); use the agentic `/v1/responses` with
    `include_server_tools` so **web search** fires; surface **widgets** as
    links/iframes to term-llm's widget pages; give term-llm tools to act on the
    Discourse knowledgebase.
- **Privacy hardening (family KB):** seed `login_required`, `invite_only`,
  `allow_index_in_robots_txt=false` via the install migration.

### term-llm connection settings

Set in Admin → Settings (the API key is server-side only, never sent to the browser):

| Setting | Notes |
|---|---|
| `second_brain_term_llm_url` | Base URL incl. base path, e.g. `https://brain.example.com/ui` |
| `second_brain_term_llm_api_key` | Bearer token for the term-llm server (secret) |
| `second_brain_term_llm_model` | Optional; blank = term-llm default |
| `second_brain_bot_username` | The assistant's account username (default `stan`) |
| `second_brain_public_category` | Category that "Make public" posts into; blank = auto-pick |

## Install (dev)

Symlinked into a Discourse checkout at `plugins/second-brain`; it builds with
Discourse. **Plugin/route/Ruby changes require a Rails server restart** (JS
hot-reloads, Ruby does not). On this branch, start a chat from the homepage
("Start a chat" → a PM with the bot).

> Display strings are hard-coded for now; make them translatable once the Blocks
> wiring is verified against a running instance.
