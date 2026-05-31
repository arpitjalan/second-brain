# Local dev setup — Discourse ⇄ term-llm (stan)

How to run the whole thing locally: chat with the bot **and** let the bot act on
the forum. This reproduces the working dev setup end-to-end. Budget ~20 minutes.

If you only want chat (not forum actions), do Part A and stop.

---

## Architecture

Two independent directions, wired separately:

```
                A. chat  (plugin calls stan's HTTP API)
   Discourse  ───────────────────────────────────────────►  term-llm "stan"
  (host :3000)                                               (docker, :8081)
        ▲                                                          │
        └──────────────────────────────────────────────────────────┘
                B. forum actions  (stan runs curl against Discourse's REST API
                                   via the `discourse` skill)
```

- **Discourse** runs on the host dev server (`localhost:3000`), with this plugin
  symlinked into `plugins/second-brain`.
- **stan** is a local `term-llm contain` Docker container serving its web API on
  `:8081` under base path `/chat`.
- **A (chat):** the plugin (`TermLlmClient`) calls `http://localhost:8081/chat/v1/responses`.
- **B (forum actions):** stan's `shell` tool runs `curl` against Discourse's REST
  API, using a `discourse` skill + credentials in its environment.

The two directions have *different* addressing problems, so set them up separately.

---

## Prerequisites

- Discourse dev checkout running (`cd ~/discourse && bin/dev`) on `localhost:3000`.
- This plugin symlinked into `~/discourse/plugins/second-brain` and enabled.
- A local term-llm `contain` instance running (the `stan` container). Create one with
  `term-llm contain new stan && term-llm contain start stan`, then confirm with
  `docker ps` — you should see `term-llm-contain-stan-app-1` (serving `:8081`).
- `docker` usable without sudo (you're in the `docker` group). On macOS this is
  Docker Desktop.
- `python3` on the host — **Linux only**, for the forwarder. macOS doesn't need it.

> **Linux and macOS both work.** The only thing that differs is the *stan → Discourse*
> hop (Part B): Linux reaches the host via the docker bridge gateway + a forwarder (and
> maybe a `ufw` rule); macOS uses Docker Desktop's `host.docker.internal` and needs
> neither. The scripted setup (`scripts/setup-local-dev.sh`) detects this for you; the
> manual steps below call it out where it matters.

Throughout, **`stan` is just the default agent/bot name** — everything is keyed off
the `AGENT` var below, so set it to whatever your agent is called (`john`, `jarvis`,
…) and the rest follows. (The scripted setup takes it as an argument:
`scripts/setup-local-dev.sh john`.) Set a couple of shell vars you'll reuse:

```bash
AGENT=stan                                # your agent / bot name (john, jarvis, …)
CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "contain-${AGENT}.*app" | head -1)
NET=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
GW=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Gateway}}')   # e.g. 172.18.0.1
SUBNET=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Subnet}}') # e.g. 172.18.0.0/16
# Each `contain` publishes its internal :8081 to a DISTINCT auto-assigned host port — discover it:
PORT=$(docker port "$CONTAINER" 8081 | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1); PORT=${PORT:-8081}
echo "agent=$AGENT  container=$CONTAINER  gateway=$GW  subnet=$SUBNET  port=$PORT"

# How the container reaches the host (used in B3/B4):
case "$(uname -s)" in
  Darwin) CONTAINER_HOST=host.docker.internal ;;  # macOS: Docker Desktop routes to host
  *)      CONTAINER_HOST="$GW" ;;                  # Linux: bridge gateway (needs forwarder)
esac
echo "container-reaches-host-via=$CONTAINER_HOST"
```

---

## Part A — Chat (Discourse → stan)

### A1. Get stan's bearer token

The plugin authenticates to stan with stan's `WEB_TOKEN`:

```bash
docker exec -u agent "$CONTAINER" sh -c 'pid=$(pgrep -f "serve web" | head -1); tr "\0" "\n" < /proc/$pid/environ | grep -E "^WEB_TOKEN=|^WEB_BASE_PATH="'
```

### A2. Point the plugin at local stan

In Discourse: **Admin → Settings → Plugins** (search "second brain"), or via
`cd ~/discourse && bin/rails runner '...'`. Set:

| Setting | Value |
|---|---|
| `second_brain_term_llm_url` | `http://localhost:$PORT/chat` |
| `second_brain_term_llm_api_key` | the `WEB_TOKEN` from A1 |
| `second_brain_bot_username` | `stan` (or your bot's username) |
| `second_brain_term_llm_model` | leave blank (stan's default) |

`localhost:$PORT` works because the container publishes its internal `:8081` to the
host — but the **host** port can differ per agent (it's auto-assigned; `8081` is just
the default container's). Check `docker ps`, which shows e.g. `0.0.0.0:$PORT->8081/tcp`,
or use the `$PORT` discovered in the prerequisites block.

### A3. Verify

Open the homepage, message stan, and you should get a streamed reply with web
search / tool calls. **Chat works now.** Stop here if you don't need forum actions.

---

## Part B — Forum actions (stan → Discourse)

The bot acts on the forum through a `discourse` skill (curl + Discourse REST API).
Four things: a key, the skill, the credentials in stan's env, and a network path.

### B1. Give the bot an admin API key

The bot acts as **itself** with an admin Discourse API key:

```bash
cd ~/discourse && SB_AGENT="$AGENT" bin/rails runner '
SiteSetting.second_brain_bot_username = ENV["SB_AGENT"]   # bot = the agent
u = SecondBrain::Bot.user                                 # find-or-create that user
u.update!(admin: true) unless u.admin?
k = ApiKey.create!(description: "second-brain dev forum actions", created_by: Discourse.system_user, user: u)
puts "BOT_USERNAME=#{u.username}"
puts "API_KEY=#{k.key}"   # shown once — copy it now
'
```

Copy `API_KEY` — the plaintext is only available at creation.

### B2. Install the `discourse` skill into stan's volume

stan discovers skills from `~/.config/term-llm/skills/` inside its persistent
volume (`/home/agent`). Drop the skill in:

```bash
docker exec -u agent "$CONTAINER" mkdir -p /home/agent/.config/term-llm/skills/discourse
docker exec -i -u agent "$CONTAINER" sh -c 'cat > /home/agent/.config/term-llm/skills/discourse/SKILL.md' \
  < ~/work/second-brain/term-llm/skills/discourse/SKILL.md
```

> Skills are scanned **once at serve startup**, so this needs a restart (B5) to be
> picked up. The skill reads `$DISCOURSE_URL` / `$DISCOURSE_API_KEY` /
> `$DISCOURSE_BOT_USERNAME` — supplied next.

### B3. Put the credentials in stan's environment

stan's `shell` tool runs commands with `zsh -c`, and **zsh sources `~/.zshenv` on
every invocation** — the cleanest place to inject env without recreating the
container. Write it into the volume (use the `$GW` and `API_KEY` from above):

```bash
docker exec -i -u agent "$CONTAINER" sh -c 'cat > /home/agent/.zshenv' <<EOF
# second-brain dev: Discourse forum credentials for the discourse skill.
export DISCOURSE_URL=http://$CONTAINER_HOST:3000
export DISCOURSE_API_KEY=<API_KEY from B1>
export DISCOURSE_BOT_USERNAME=$AGENT
EOF
```

`DISCOURSE_URL` uses `$CONTAINER_HOST` from the prerequisites: on **Linux** that's
the **docker gateway IP** (`$GW`, e.g. `172.18.0.1`) — not `localhost`, see B4 — and
on **macOS** it's `host.docker.internal`, which Docker Desktop routes to the host
loopback directly.

> If your container's shell is not zsh, `.zshenv` won't be read. Check with
> `docker exec -u agent "$CONTAINER" sh -c 'echo $SHELL'`. For bash you'd instead need
> `BASH_ENV` set in the process env (requires recreating the container), or bake the
> values into the skill. zsh is the default for the `contain` image.

### B4. Make Discourse reachable from the container

> **macOS: skip this whole section.** Docker Desktop's `host.docker.internal`
> (already in `$CONTAINER_HOST`) reaches the host's `127.0.0.1:3000` directly — no
> forwarder, no `ufw`. Go straight to B5. (If you use a non-Desktop runtime like
> colima or podman, you may need to start the container with
> `--add-host=host.docker.internal:host-gateway`.)

**Linux only.** This is the fiddly bit. The dev server binds `127.0.0.1:3000`
**only**, and the container's `localhost` is its own — so stan can't reach Discourse
directly. Bridge it onto the docker gateway with the forwarder, and open the firewall
for it.

1. **Run the forwarder on the host** (gateway:3000 → loopback:3000). Keep it running
   for your dev session:
   ```bash
   nohup python3 ~/work/second-brain/scripts/dev-discourse-forwarder.py "$GW" 3000 127.0.0.1 3000 \
     > /tmp/sb-fwd.log 2>&1 &
   ```

2. **Allow the container subnet through ufw** (if ufw is active — check with
   `sudo ufw status`). This is the one step that needs sudo. Because **each agent
   gets a new docker subnet** (stan `172.18.0.0/16`, jarvis `172.19.0.0/16`, …),
   allow the whole docker range **once** so every present + future agent is covered:
   ```bash
   sudo ufw allow from 172.16.0.0/12 to any port 3000 proto tcp comment 'dev: containers->discourse'
   ```
   (Narrower, just one agent: `sudo ufw allow from "$SUBNET" to any port 3000 proto tcp`.)
   Without this, the container→host hop is refused/dropped — the agent reaches
   localhost for chat but **can't act on the forum** (create topics etc.), and its
   API calls time out. This is per-firewall, not per-trust-level: the bot is TL4
   and allowed to post; it just can't reach Discourse.

Using an **IP** (the gateway) as the host also sidesteps Rails' "Blocked hosts"
guard — Discourse dev allows all IPs by default, so no host-auth config needed.

### B5. Enable forum actions + restart stan

```bash
# enable the plugin-side context injection:
cd ~/discourse && bin/rails runner 'SiteSetting.second_brain_forum_actions_enabled = true'

# restart stan so it discovers the skill, then wait for it to come back:
docker restart "$CONTAINER"
for i in $(seq 1 20); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/chat/)" = "200" ] && break; sleep 1
done; echo "$AGENT up"
```

### B6. Verify

```bash
# env reaches the shell tool:
docker exec -u agent "$CONTAINER" zsh -c 'echo "$DISCOURSE_URL  $DISCOURSE_BOT_USERNAME  ${DISCOURSE_API_KEY:0:8}…"'

# skill is discovered:
docker exec -u agent "$CONTAINER" term-llm skills show discourse | head -3

# full path works (container → forwarder → Discourse → API auth):
docker exec -u agent "$CONTAINER" zsh -c \
  'curl -sS -w "\nHTTP %{http_code}\n" -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" "$DISCOURSE_URL/session/current.json"'
```

The last command should return the bot's session JSON with `"username"` matching your
agent (e.g. `"stan"`) and `HTTP 200`. Then **test for real**: in a chat, ask the bot to *"create a forum topic
titled '…' with a short body"*. You'll see the `activate_skill` + `shell` tool
calls, and the topic appears under `/latest`.

## Part C — Interactive questions (`ask_user`) timeout

The bot can pause mid-answer to ask structured questions (see
[ask-user.md](ask-user.md)) — that works out of the box, no setup. But a paused run
only lives for term-llm's `serve.response_timeout` (**default 30 min**), so a family
member answering hours later would hit a "this question expired" message. For async
answering, raise it on stan:

```bash
# add `response_timeout: 24h` under the `serve:` block of stan's config (idempotent):
docker exec -i -u agent "$CONTAINER" python3 - <<'PY'
p = "/home/agent/.config/term-llm/config.yaml"
s = open(p).read()
if "response_timeout" not in s:
    open(p, "w").write(s.replace("serve:\n", "serve:\n    response_timeout: 24h\n", 1))
PY
term-llm contain restart "$AGENT"   # or: docker restart "$CONTAINER"
```

The config lives in stan's persistent volume, so it survives restarts/recreates.

---

## Part D — Add a personal agent (multi-agent)

The plugin supports a shared **family** agent (`stan`, admin) plus opt-in
**personal** agents — each its own term-llm container + Discourse bot user, a TL4
(non-admin) user **private to its owner**. See `docs/design-multi-agent.md` for
the design. Provisioning is one command:

```bash
# 1. stand up the agent's container (its own host port is auto-assigned)
term-llm contain new stan-arpit && term-llm contain start stan-arpit

# 2. wire it as a personal agent owned by member "arpit"
scripts/setup-local-dev.sh stan-arpit --owner arpit
```

`--owner` makes it a TL4 (non-admin) bot, mints its own user-scoped forum key,
and writes a row in the `second_brain_agents` registry pointing at that
container's url/token + owner — **without touching the family settings**. After a
`bin/dev` restart + refresh, `arpit` sees an agent switcher on the homepage and
their own widgets in the sidebar; no one else can reach `stan-arpit`.

To remove one: `DELETE FROM second_brain_agents WHERE bot_user_id = <id>` (or via
the rails console) and stop its container.

---

## What persists vs. what's per-session

| Persists across restarts | Re-do each dev session |
|---|---|
| `.zshenv`, skill (in stan's volume) | the forwarder process — **Linux only** (re-run B4.1) |
| Discourse settings + API key | — |
| the ufw rule (Linux) | — |

So on Linux you usually only restart the forwarder day-to-day. On **macOS** nothing
in this table is per-session — `host.docker.internal` is always there, so once you've
done Parts A/B the setup just keeps working across restarts.

---

## Troubleshooting

- **`stan -> Discourse failed (HTTP 000)`** — `000` means curl couldn't connect at
  all (not an auth error). The #1 cause is **Discourse not running**: the forwarder
  has nothing behind it. Check `curl http://127.0.0.1:3000/` on the host — if that
  fails, `cd ~/discourse && bin/dev` and wait for "Listening on 127.0.0.1:3000", then
  re-test. (The script's `rails runner` steps still succeed with the web server down,
  so chat config can look complete while this check fails.)
- **`Blocked hosts: <name>`** — Rails host-auth rejecting a DNS hostname. Using the
  gateway IP (B3) avoids it. If you use a tunnel hostname instead, allow it in
  `~/discourse/config/environments/development.rb` (e.g.
  `config.hosts << /\.trycloudflare\.com\Z/`) and restart the dev server.
- **Connection times out from the container** — *Linux:* ufw is dropping it (do B4.2)
  or the forwarder is down (`curl http://$GW:3000/` from the host should return 200).
  *macOS:* confirm Discourse is up on `127.0.0.1:3000` and that the runtime provides
  `host.docker.internal` (`docker exec -u agent "$CONTAINER" getent hosts host.docker.internal`).
- **`connection refused … [::1]:3000`** (only relevant with a tunnel) — `localhost`
  resolved to IPv6; point the tunnel at `http://127.0.0.1:3000` explicitly.
- **Skill not found / stan answers instead of acting** — restart stan (skills are
  scanned at startup), confirm `term-llm skills show discourse`, and that
  `second_brain_forum_actions_enabled` is on.
- **`$DISCOURSE_URL` empty in a command** — the shell isn't zsh, or `.zshenv` is
  missing; see the note in B3.
- **Links stan returns aren't clickable** — they use the internal gateway IP
  (`http://$GW:3000/...`); swap the host for `localhost:3000` to open them. Cosmetic
  in dev only.

---

## Remote variant (DO droplet / production stan)

The droplet runs the **same `contain` image**, so B1/B2/B3/B5 are identical — only
the network path (B4) changes. There, stan is remote and must reach **your**
Discourse, so instead of the host forwarder you expose Discourse publicly (e.g. a
Cloudflare tunnel: `cloudflared tunnel --url http://127.0.0.1:3000`) and set
`DISCOURSE_URL` to that public address. Everything else is the same.

---

## Teardown / revert to droplet stan

```bash
# stop the forwarder:
pkill -f dev-discourse-forwarder.py
# (optional) remove the ufw rule:
sudo ufw delete allow from <SUBNET> to any port 3000 proto tcp
# point the plugin back at your remote/droplet stan:
cd ~/discourse && bin/rails runner '
SiteSetting.second_brain_term_llm_url = "https://your-stan-host.example.com/chat/"
SiteSetting.second_brain_term_llm_api_key = "<droplet WEB_TOKEN>"'
```
