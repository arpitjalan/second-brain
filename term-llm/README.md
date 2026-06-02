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

**Setup is one command, run on the term-llm server.** `scripts/setup-dv.sh` does
the whole two-machine dance for you — installs the skill, mints the locked key,
installs the guard on the dev box *over your own SSH login*, writes the `dvhost`
alias with the right address, and verifies both that `dv` works and that the guard
refuses everything else. The transport between the two machines is your choice —
LAN, VPN, jump host, or [Tailscale](https://tailscale.com) (recommended; see
"Networking" below).

### Prerequisite (on the dev machine)

**Docker must already be installed and running**, then install `dv`:

```bash
# 1. Docker — dv DRIVES Docker but does NOT install it. Use your OS's Docker
#    install and make sure `docker info` works for your user.
# 2. dv — its installer just drops the dv binary into ~/.local/bin (no sudo):
curl -sSfL https://raw.githubusercontent.com/discourse/dv/main/install.sh | sh
```

### Setup (one command, on the term-llm server)

You need your normal (admin) SSH login to the dev box. The script uses it **once,
at setup time**, to install the locked key; the bot itself only ever holds the
`dv`-only key.

```bash
scripts/setup-dv.sh me@devbox          # me@devbox = how THIS server reaches the dev box
# or, if devbox is already a Host in your ~/.ssh/config:  scripts/setup-dv.sh devbox
```

That one command (idempotent — safe to re-run):

1. installs the dv skill into `~/.config/term-llm/skills/dv/`;
2. mints the `dv`-only key `~/.ssh/dvhost_ed25519` (reused unless `--new-key`);
3. `scp`s `dv-ssh-guard.py` to the dev box and runs its self-installer there, so the
   bot's **public** key rides over as an argument — never copy/pasted by hand. The
   key can run any `dv` command (including commands *inside* dv's disposable
   containers — the sandbox) but **nothing else**: no shell, no `git`/`gh`, no
   `scp`. So the bot can build/test/`extract` but **can't push or open a PR** —
   that's left to you;
4. writes the `Host dvhost` block into `~/.ssh/config` with **`HostName` = the
   address you just reached the dev box at** — correct by construction, even behind
   Tailscale/NAT, with no hand-edit and no config block to paste back; and
5. verifies the key works **and** that a non-`dv` command is refused — proving the
   guard is actually guarding.

Handy flags: `--host-name ADDR` (bake a different reach address than you SSH'd in
over — e.g. a stable Tailscale name), `--alias NAME` (a second dev box / key),
`--port N`, `--new-key`. Private repo? `export GITHUB_TOKEN=<PAT>` so the script can
fetch the skill/guard from GitHub when there's no local checkout on the server.

> ⚠️ **The dev machine must be awake and online** for any of this to work — a
> sleeping laptop = the job fails. Best for *attended* use ("I'm around, go test
> this PR"), not unattended 3am jobs.

<details>
<summary><strong>Doing it by hand</strong> — if the server has no admin SSH to the dev box, or you'd rather not script it</summary>

1. **Install the skill** on the term-llm server:
   ```bash
   mkdir -p ~/.config/term-llm/skills/dv
   curl -fsSL https://raw.githubusercontent.com/arpitjalan/second-brain/main/term-llm/skills/dv/SKILL.md \
     -o ~/.config/term-llm/skills/dv/SKILL.md
   # …or from a checkout:  cp term-llm/skills/dv/SKILL.md ~/.config/term-llm/skills/dv/SKILL.md
   ```
   (Private repo? add `-H "Authorization: token <PAT>"` — without it `-fsSL` fails
   silently and leaves an empty file.)

2. **Generate the bot's key** on the server:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/dvhost_ed25519 -N "" -C dvhost-dv
   cat ~/.ssh/dvhost_ed25519.pub        # copy this public key for step 3
   ```

3. **On the dev machine** (Docker + `dv` already installed — see Prerequisite),
   run the self-installing guard with that public key:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/arpitjalan/second-brain/main/term-llm/dv-ssh-guard.py -o dv-ssh-guard.py
   python3 dv-ssh-guard.py --install "ssh-ed25519 AAAA…botkey dvhost-dv"
   ```
   It adds the locked `restrict,command="…"` entry and **prints the `~/.ssh/config`
   block** for step 4 (auto-detecting a Tailscale `HostName` when present).

4. **On the term-llm server:** paste that block into `~/.ssh/config` (fill in
   `HostName` if it printed a placeholder), then verify:
   ```bash
   ssh dvhost -- dv version   # reachable + dv present
   ssh dvhost -- dv list      # the Docker daemon on the dev machine is up
   ```
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
