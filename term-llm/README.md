# term-llm integration — making the bot Discourse-aware

This folder holds the **term-llm side** of the integration (the bot acting *on*
the forum). The Discourse plugin handles the rest.

## `skills/discourse/SKILL.md`

A term-llm skill that teaches the bot to act on the family forum via Discourse's
REST API (create topics, reply, search, send PMs). The bot always acts as
**itself** (its own admin bot account) — no impersonation.

### Deploy (on the term-llm server)

1. Install the skill into the bot's skills directory. Fetch it straight from
   GitHub (no checkout needed — once the repo is public), or `cp` it if you have
   the repo on the host:
   ```bash
   mkdir -p ~/.config/term-llm/skills/discourse
   # from GitHub:
   curl -fsSL https://raw.githubusercontent.com/arpitjalan/second-brain/main/term-llm/skills/discourse/SKILL.md \
     -o ~/.config/term-llm/skills/discourse/SKILL.md
   # …or from a checkout:  cp term-llm/skills/discourse/SKILL.md ~/.config/term-llm/skills/discourse/SKILL.md
   term-llm skills validate discourse   # optional
   ```
   (While the repo is private, add `-H "Authorization: token <PAT>"` to the curl,
   or `scp` the file over.)
2. Set these env vars for the `term-llm serve` process:
   ```bash
   export DISCOURSE_URL="https://<forum-url-reachable-from-term-llm>"   # NO trailing slash
   export DISCOURSE_API_KEY="<the bot's admin API key>"
   export DISCOURSE_BOT_USERNAME="<the bot account username>"           # e.g. stan
   ```

## `skills/dv/SKILL.md`

A term-llm skill that teaches the bot to drive the [`dv`](https://github.com/discourse/dv)
("Discourse Vibe") CLI — spin up throwaway Discourse dev containers, run the test
suite, check out a branch/PR, and prepare changes. This is for *developing on*
Discourse, distinct from the `discourse` skill (which acts on the live family
forum).

**How it fits together** — `dv` needs Docker, and you don't want the bot's
production container holding the host Docker socket (that's root-on-prod via
prompt injection). So `dv` runs on a separate **dev machine**, and the bot
reaches it over an SSH key **locked to `dv` and nothing else**:

```text
      you, in the Discourse forum
                │  "stan, test PR #29481"
                ▼
  ┌───────────────────────────┐   SSH    ┌───────────────────────────┐
  │ term-llm server  (stan)   │  ──────► │ dev machine               │
  │ • runs `term-llm serve`   │ dv-only  │ • runs `dv` + Docker      │
  │ • holds the dv-only key   │   key    │ • spins up throwaway      │
  │   (ssh alias: dvhost)     │          │   Discourse containers    │
  └───────────────────────────┘          └───────────────────────────┘
     your forum host                       your laptop / a dev box
```

**Setup is one command** — run from whichever of the two machines can SSH into the
other. Three entry points, identical end result: `scripts/setup-dv.sh` (on the
term-llm server, when it can reach the dev box), `scripts/setup-dv-from-devbox.sh`
(on the dev box, when term-llm is on a hosted server that can't — the common case),
and `scripts/setup-dv-for-agent.sh` (on the dev box, when term-llm runs as **per-agent
containers** — `term-llm contain` — so dv is scoped to one named agent's container
volume). Each installs the skill, sets up the `dv`-only key, writes the `dvhost`
alias with the right address, and verifies the guard. The transport between the two
machines is your choice — LAN, VPN, jump host, or [Tailscale](https://tailscale.com)
(recommended; see "Networking" below).

### Prerequisite (on the dev machine)

**Docker must already be installed and running**, then install `dv`:

```bash
# 1. Docker — dv DRIVES Docker but does NOT install it. Use your OS's Docker
#    install and make sure `docker info` works for your user.
# 2. dv — its installer just drops the dv binary into ~/.local/bin (no sudo):
curl -sSfL https://raw.githubusercontent.com/discourse/dv/main/install.sh | sh
```

### Setup — one command, from whichever side can reach the other

Run **one** of these, depending on which machine can SSH into the other (the end
result is identical, and the bot only ever ends up with the `dv`-only key):

#### From the term-llm server — when it can admin-SSH the dev box

For an always-on dev box / VM you administer from the term-llm host. You need your
normal SSH login to the dev box.

```bash
scripts/setup-dv.sh me@devbox          # me@devbox = how THIS server reaches the dev box
# or, if devbox is already a Host in your ~/.ssh/config:  scripts/setup-dv.sh devbox
```

It (idempotent — safe to re-run): installs the skill; mints the `dv`-only key
`~/.ssh/dvhost_ed25519`; `scp`s the guard to the dev box and self-installs it (the
**public** key rides over as an argument, never pasted); writes the `Host dvhost`
block with **`HostName` = the address you just reached** (correct by construction,
no hand-edit); and verifies the key works **and** that a non-`dv` command is refused.
Flags: `--host-name ADDR`, `--alias NAME`, `--port N`, `--new-key`.

#### From the dev box — when term-llm is on a hosted server / droplet (the common case)

When the server **can't** SSH into the dev box (term-llm on a **DigitalOcean
droplet**, the dev box a laptop behind NAT). Run this **on the dev box**, over the
SSH login you already have **into the server** — it drives setup the other way, so
the droplet never gets admin access to your machine.

```bash
scripts/setup-dv-from-devbox.sh me@droplet   # me@droplet = your login to the term-llm server
```

It (idempotent): installs the skill onto the server; generates the `dv`-only key
**on the server** (private half never leaves it); locks **this box's**
`authorized_keys` to it via the guard; writes the server's `Host dvhost` block with
**`HostName` = this box's Tailscale name** (auto-detected); and verifies, from here,
that the server can run `dv` and that a non-`dv` command is refused. Flags:
`--reach-name ADDR`, `--alias NAME`, `--port N` (server SSH port), `--reach-port N`
(this box's sshd port), `--new-key`.

Extra prerequisites for this direction, **on the dev box**: an **SSH server** must
be running (the term-llm server connects *into* it — macOS: enable Remote Login),
and the server needs a path to reach back — **[Tailscale](https://tailscale.com)**
recommended (both machines on the tailnet; `--reach-name` then defaults to this
box's MagicDNS name). The server reaches the dev box at runtime regardless, so this
path is required either way.

On **Linux** sshd usually isn't running yet — start it, but expose it *only* over
the tailnet, never the whole LAN/internet (the `dv` guard then locks what the key
can do — defense in depth). Bind sshd to this box's Tailscale IPs and keep auth
key-only by dropping a `/etc/ssh/sshd_config.d/10-tailscale-only.conf` (use your own
addresses from `tailscale ip`):

```conf
ListenAddress 100.x.y.z                       # your tailnet IPv4
ListenAddress fd7a:…                          # …and IPv6, if you use it
PasswordAuthentication no
```

then `sudo ssh-keygen -A` (first-run host keys, else `sshd -t` errors with "no
hostkeys available") and `sudo systemctl enable --now sshd`. Confirm it bound to the
tailnet and **not** `0.0.0.0`: `ss -tlnH 'sport = :22'`.

Private repo? `export GITHUB_TOKEN=<PAT>` so either script can fetch the skill/guard
from GitHub when there's no local checkout.

> ⚠️ **The dev machine must be awake and online** for any of this to work — a
> sleeping laptop = the job fails. Best for *attended* use ("I'm around, go test
> this PR"), not unattended 3am jobs.

#### When term-llm runs as per-agent containers (`term-llm contain`)

The two scripts above assume `term-llm serve` is a **host process** and install the
skill + dv-only key into the **SSH-login user's home** (`~/.config/term-llm/skills`,
`~/.ssh`). But a containerised deployment runs each agent in its own container
(`term-llm-contain-<agent>-app-1`) with its own `/home/agent` **volume**, and the
agent reads skills + ssh config from *there* — it never looks at the login user's
home. So `setup-dv.sh` / `setup-dv-from-devbox.sh` would report a green ✅ while
granting **no agent** dv. Use the container-aware script instead, run **on the dev
box**, which provisions **one named agent's** container volume:

```bash
scripts/setup-dv-for-agent.sh jarvis me@droplet   # agent name + your login to the server
```

It (idempotent): installs the skill into `jarvis`'s container volume; generates the
dv-only key **inside that container**; locks this box's `authorized_keys` to it via
the guard; writes the `Host dvhost` block into the agent's in-container `~/.ssh/config`
(`HostName` = this box's Tailscale IP, auto-detected — robust from inside Docker,
which NATs the container out through the host's tailnet); verifies **from inside the
container** that `dv` works and a non-`dv` command is refused; then
`term-llm contain restart jarvis` so serve rescans skills. Flags: `--container NAME`,
`--reach-name ADDR`, `--agent-user`/`--agent-home`, `--port`/`--reach-port`,
`--new-key`, `--no-restart`.

**dv is per-agent here** — only the agent(s) you run this for get it. Give it to the
one dev-facing bot, not all of them (least privilege: each container holding the key
can drive Docker on your dev box). Repeat for another agent if you really want it.

<details>
<summary><strong>Doing it by hand</strong> — the fully manual steps, if you'd rather not run a script</summary>

You do every step yourself across the two machines (this is the by-hand version of
`setup-dv-from-devbox.sh`), so the server never needs admin access to the dev box —
it only ends up with the `dv`-only key.

0. **Make the dev box reachable from the server first.** The bot runs `ssh dvhost
   -- dv …` *from the server*, so the server must be able to reach the dev box — a
   droplet can't reach a laptop behind NAT on its own. Put both on the same
   [Tailscale](https://tailscale.com) tailnet (`sudo tailscale up` on each — **not**
   Tailscale SSH; see Networking) and note the dev box's MagicDNS name from
   `tailscale status`.

1. **Install the skill** on the term-llm server:
   ```bash
   mkdir -p ~/.config/term-llm/skills/dv
   curl -fsSL https://raw.githubusercontent.com/arpitjalan/second-brain/main/term-llm/skills/dv/SKILL.md \
     -o ~/.config/term-llm/skills/dv/SKILL.md
   # …or from a checkout:  cp term-llm/skills/dv/SKILL.md ~/.config/term-llm/skills/dv/SKILL.md
   ```
   (Private repo? add `-H "Authorization: token <PAT>"` — without it `-fsSL` fails
   silently and leaves an empty file.)

2. **Generate the bot's key** on the server and copy its public half:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/dvhost_ed25519 -N "" -C dvhost-dv
   cat ~/.ssh/dvhost_ed25519.pub        # copy this whole line for step 3
   ```

3. **On the dev box** (Docker + `dv` already installed — see Prerequisite), run the
   self-installing guard with that public key, **as the user the bot should log in
   as**:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/arpitjalan/second-brain/main/term-llm/dv-ssh-guard.py -o dv-ssh-guard.py
   python3 dv-ssh-guard.py --install "ssh-ed25519 AAAA…paste the pubkey… dvhost-dv"
   ```
   It adds the locked `restrict,command="…"` entry to *that* user's
   `authorized_keys` and **prints a `Host dvhost` block** — auto-filling your
   Tailscale `HostName` when it can detect it.

4. **Back on the server:** paste that block into `~/.ssh/config` (set `HostName` to
   the dev box's reachable name if it printed a placeholder; `User` is the dev-box
   user from step 3), then verify:
   ```bash
   ssh dvhost -- dv version   # reachable + dv present
   ssh dvhost -- dv list      # Docker on the dev box is up
   ssh dvhost -- echo hi      # MUST be refused ("only `dv` …") — the guard working
   ```

5. **Restart `term-llm serve`** (or its container) so it scans the new skill.
</details>

#### Networking — Tailscale recommended (not required)

The skill only ever runs `ssh dvhost …`, so *how* the dev machine is reachable
lives entirely in the `dvhost` alias's `HostName` — change networks, edit one
line. [Tailscale](https://tailscale.com) is the easiest reliable option: a fixed
MagicDNS name for a roaming laptop, no inbound port-forward, WireGuard-encrypted,
and ACLs that can allow only the term-llm node to reach port 22.

Keep Tailscale at the *network* layer only — **don't use Tailscale SSH.** It
bypasses `authorized_keys` and therefore the `dv`-only guard. Tailscale gives
*reachability*; the guard gives *authorization*.

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
