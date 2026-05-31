# term-llm integration — making the bot Discourse-aware

This folder holds the **term-llm side** of the integration (the bot acting *on*
the forum). The Discourse plugin handles the rest.

## `skills/discourse/SKILL.md`

A term-llm skill that teaches the bot to act on the family forum via Discourse's
REST API (create topics, reply, search, send PMs). The bot always acts as
**itself** (its own admin bot account) — no impersonation.

### Deploy (on the term-llm server)

1. Copy the skill into the bot's skills directory:
   ```bash
   mkdir -p ~/.config/term-llm/skills/discourse
   cp skills/discourse/SKILL.md ~/.config/term-llm/skills/discourse/SKILL.md
   term-llm skills validate discourse   # optional
   ```
2. Set these env vars for the `term-llm serve` process:
   ```bash
   export DISCOURSE_URL="https://<forum-url-reachable-from-term-llm>"   # NO trailing slash
   export DISCOURSE_API_KEY="<the bot's admin API key>"
   export DISCOURSE_BOT_USERNAME="<the bot account username>"           # e.g. stan
   ```

## On the Discourse side

> **Tip:** the plugin's rake tasks automate this side and **print the exact
> `DISCOURSE_URL` / `DISCOURSE_BOT_USERNAME` / `DISCOURSE_API_KEY`** to paste above —
> `rake second_brain:set_family_agent` (family) or `rake second_brain:add_agent`
> (personal) ensure the bot account, mint + print its API key, and enable forum
> actions. See the plugin README, "Agents on a live server". The manual steps below
> are the equivalent if you'd rather do it by hand.

1. **Make the bot account an admin** and **create a global API key** for it
   (Admin → API Keys → New → User = the bot, Scope = Global). Put that key in
   `DISCOURSE_API_KEY` above. (The bot username is the plugin's
   `second_brain_bot_username` setting — keep `DISCOURSE_BOT_USERNAME` in sync.)
2. Turn on the site setting **`second_brain_forum_actions_enabled`** — this makes
   the plugin add a short system note to each chat telling the bot it's in the
   forum, who it's talking to, and that it can act via the `discourse` skill.

## ⚠️ Networking

term-llm must be able to **reach the Discourse forum's URL**. In local dev,
Discourse on `localhost:3000` is NOT reachable from a remote term-llm server —
expose Discourse with a tunnel (ngrok/cloudflared) and set `DISCOURSE_URL` to
that public address for testing.
