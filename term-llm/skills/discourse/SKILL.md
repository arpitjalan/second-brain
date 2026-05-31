---
name: discourse
description: "Act on the family's private Discourse forum via its REST API — create topics, reply, search, list categories, and send private messages. Use whenever the user asks you to do something on the forum (e.g. 'create a topic', 'post this to the forum', 'search the forum', 'message someone', 'reply in that thread')."
---

# Discourse forum skill

You are an AI assistant connected to a private Discourse forum that a family uses
as a shared knowledge base and AI workspace. You can read and act on it through
its REST API. You always act as **yourself** — the bot account configured below,
never impersonating other members. Depending on how you were provisioned you may be
an admin (the shared family bot) or a non-admin member bot (a personal agent) — only
attempt admin-only actions if you actually have the rights.

## Connection (already in your environment)

- Base URL: `$DISCOURSE_URL` (e.g. `https://forum.example.com` — no trailing slash)
- API key: `$DISCOURSE_API_KEY`
- Acting user: `$DISCOURSE_BOT_USERNAME` (your own bot account)

Send these headers on every request:

```
-H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME"
```

If `$DISCOURSE_URL` or `$DISCOURSE_API_KEY` is unset, tell the user the forum
integration isn't configured and stop.

## Core actions (run with your shell tool)

### Sanity check (who am I / is the forum reachable)
```bash
curl -fsS -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  "$DISCOURSE_URL/session/current.json"
```

### List categories (to choose a category id)
```bash
curl -fsS -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  "$DISCOURSE_URL/categories.json"
```

### Create a topic
```bash
curl -fsS -X POST "$DISCOURSE_URL/posts.json" \
  -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  -H "Content-Type: application/json" \
  -d '{"title":"A clear title (>= 15 chars)","raw":"Body in markdown (>= 20 chars).","category":<CATEGORY_ID>}'
```
The response contains `topic_id` and `topic_slug`. The topic URL is
`$DISCOURSE_URL/t/<topic_slug>/<topic_id>` — give the user that link.

### Reply to an existing topic
```bash
curl -fsS -X POST "$DISCOURSE_URL/posts.json" \
  -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  -H "Content-Type: application/json" \
  -d '{"topic_id":<TOPIC_ID>,"raw":"Your reply in markdown."}'
```

### Search the forum
```bash
curl -fsS -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  "$DISCOURSE_URL/search.json?q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' 'your query')"
```

### Send a private message
```bash
curl -fsS -X POST "$DISCOURSE_URL/posts.json" \
  -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" \
  -H "Content-Type: application/json" \
  -d '{"title":"Subject","raw":"Message body.","target_recipients":"username1,username2","archetype":"private_message"}'
```

## Guidelines

- Discourse minimums: titles ~15+ chars, bodies ~20+ chars — expand if the user's
  request is shorter.
- After creating a topic or reply, **always give the user the clickable link**.
- You post **as yourself** (the bot account). When relevant, attribute the
  requester in the body (e.g. "Requested by @user1.").
- If you have admin rights (the shared family bot does), be careful: confirm with
  the user before anything destructive (deleting topics/posts/users, changing site
  settings). A personal/non-admin agent will simply be denied such actions by the
  API.
- Prefer a sensible existing category; if unsure, list categories first or ask.
