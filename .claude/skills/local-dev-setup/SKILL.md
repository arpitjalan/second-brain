---
name: local-dev-setup
description: "Set up or repair the local dev environment for the second-brain Discourse plugin and its term-llm bot (stan) — chat plus forum actions. Use when the user asks to set up local dev, connect Discourse to a local stan, wire up forum actions, get the bot acting on the forum, fix the stan↔Discourse connection, or 'do that setup again'."
---

# Local dev setup (Discourse ⇄ term-llm "stan")

This repo's plugin makes Discourse the UI for a local `term-llm` bot. Getting both
directions working locally — chat (Discourse → stan) and forum actions
(stan → Discourse) — is fully scripted. **Prefer the script over doing it by hand.**

## Do this

1. Run the idempotent setup script (safe to re-run):
   ```bash
   scripts/setup-local-dev.sh
   ```
   It discovers the stan container + docker network, reads stan's bearer token,
   makes the bot an admin with a Discourse API key, installs the `discourse` skill
   and credentials into stan's volume, starts the host TCP forwarder, points the
   plugin at local stan, enables forum actions, restarts stan, and verifies the
   `stan → Discourse` path.

2. **The one step the script can't do** (needs sudo, so the user must run it):
   if the final check fails because `ufw` is dropping the container→host hop, the
   script prints the exact rule, e.g.
   ```bash
   sudo ufw allow from <SUBNET> to any port 3000 proto tcp comment 'dev: stan->discourse'
   ```
   Ask the user to run it (in Claude Code they can use the `!` prefix), then re-run
   the script or just re-test.

3. To rotate the bot's API key: `scripts/setup-local-dev.sh --new-key`.

## Notes for the agent

- Prerequisites: Discourse dev server up on `localhost:3000` with this plugin
  symlinked in, and a local stan `contain` container running (`docker ps`).
- The forwarder is a **per-session** background process; if `stan → Discourse`
  breaks later, just re-run the script (it restarts the forwarder if needed).
- The script **restarts the stan container** (skills are scanned at startup), so
  avoid running it while the user is mid-chat unless they're okay with a brief blip.
- Full explanation, troubleshooting, and the remote (DO droplet) variant are in
  `docs/local-dev.md`. Read it if the script fails in a way not covered above.
