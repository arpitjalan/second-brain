---
name: dv
description: "Drive throwaway Discourse development environments via the `dv` (Discourse Vibe) CLI — create an isolated container, run commands and Discourse's test suite inside it, check out a branch or PR, make code changes, and pull them back out. Use this skill whenever a member mentions `dv` at all or asks you to run ANY `dv` command (e.g. `dv ls`/`dv list`, `dv version`, `dv new`, `dv run`), list or inspect Discourse dev workspaces/containers, check whether the dev box is reachable, set up or spin up a Discourse dev environment, try a plugin or theme, run Discourse/plugin specs, check out or test a PR or branch, or prepare a code change to Discourse or a plugin. Just run `dv <args…>` through your shell tool — a local wrapper transparently forwards it to the remote dev machine over SSH; never run `docker` directly."
---

# Discourse Vibe (dv) skill

`dv` runs full Discourse development environments inside Docker containers. Each
environment (dv calls it an **agent**, but think *workspace*) is an isolated
checkout of Discourse with its dev + test databases, ready to run, edit, and
test. This is for *developing on* Discourse — separate from the `discourse`
skill, which acts on the live family forum over REST.

**`dv` here is a thin wrapper.** The real `dv` runs on a separate **dev machine**,
reached over SSH (the `dvhost` alias, using a key **locked to `dv` and nothing
else**); the `dv` on this machine just forwards your arguments there. So simply run
your commands through your **shell tool**:

```bash
dv <args…>
```

It transparently executes on the dev machine — you don't need to know the transport
(Tailscale, LAN, VPN, a jump host), and you do **not** prefix anything with `ssh`.
(The explicit `ssh dvhost -- dv <args…>` form works too, if you ever need it.)

## Before you start — is the dev machine reachable?

```bash
dv version    # the wrapper + SSH work and dv is installed on the dev machine
dv list       # the Docker daemon on the dev machine is up
```

If `dv version` fails with a connection/timeout error, the dev machine is
**unreachable** (powered off, asleep, or off the network) or the integration isn't
set up. Tell the member plainly and stop — do **not** try to install or configure
anything; the key only permits `dv`, so nothing else will run anyway.

## What the locked key allows — and what it doesn't

- ✅ **Any `dv …` command**, including `dv run … -- <cmd>`, which runs commands
  **inside dv's disposable Discourse containers** — that's the intended sandbox.
- ❌ **Anything that isn't `dv`** on the dev machine: no plain shell, no
  `git`/`gh`, no `scp`, no file copies off the box, and **no `docker`** (don't run
  `docker` directly — it isn't available to you; go through `dv`). You can build,
  test, and `extract`, but you **cannot push or open a PR** from here — that's left
  to the member. If a command comes back refused ("only `dv` …"), that's the
  security guard working as intended; don't try to route around it.

## The workspace model (read this first)

- `dv list` shows all workspaces; one is the globally **selected** one.
- **Create/switch** commands take the name **positionally**: `dv new NAME`,
  `dv select NAME`, `dv rename OLD NEW`.
- **Action** commands take **`--name NAME`**: `dv run --name NAME -- …`,
  `dv pr --name NAME …`, `dv stop --name NAME`. **Always pass `--name`** so you
  never depend on — or clobber — the selected workspace.
- Name workspaces after the task: `stan-task-1`, `try-kanban`, `pr-29481`.
  One task = one workspace; remove it when done.

## Create an isolated workspace

```bash
dv new stan-task-1                            # fresh Discourse workspace
dv new --plugin discourse-kanban stan-kanban  # …with a plugin preinstalled
```

`dv new` (and PR/branch checkouts) can take **several minutes** — tell the member
it's running rather than going silent.

## Run a command inside a workspace

`dv` executes as the `discourse` user in the Discourse checkout
(`/var/www/discourse`). Prefer running programs **directly** — it keeps SSH
quoting simple and avoids nested shells:

```bash
dv run --name stan-task-1 -- git rev-parse --short HEAD
```

Issue separate calls instead of chaining commands; don't wrap things in
`bash -lc 'a && b'` unless you truly need a shell.

## Run Discourse's tests

```bash
# Core Ruby specs for a path:
dv run --name stan-task-1 -- bin/rspec spec/models/user_spec.rb
# A plugin's specs:
dv run --name stan-task-1 -- bin/rspec plugins/<plugin>/spec
```

Report pass/fail and the relevant output back to the member — don't just say
"done".

## Check out a PR or branch (resets the env)

```bash
dv pr --name stan-task-1 29481              # checkout PR #29481, full DB reset
dv branch --name stan-task-1 --new my-fix   # checkout (or create) a branch
```

Both drop & reseed the databases (slow). Add `--no-reset` to skip that and only
run migrations when you just need the code.

## Make a change, then hand it off

You can edit and test, but the locked key can't push or open a PR. So:

1. Apply edits inside the container and run the relevant tests (above) until
   they pass.
2. Pull the changes onto the dev machine as a branch at the container's HEAD:
   ```bash
   dv extract --name stan-task-1                  # whole checkout
   dv extract plugin <plugin> --name stan-task-1  # a single plugin
   ```
3. Tell the member the **branch name and where it landed on the dev machine**,
   and that they can push it / open the PR from there. Do not attempt the push
   yourself.

## Clean up

```bash
dv stop --name stan-task-1
dv remove --force stan-task-1   # delete the throwaway workspace
```

## Guidelines & safety

- **Confirm before destructive or slow actions.** `dv remove`, `dv reset`, and
  `dv pr` / `dv branch` drop & reseed databases and take minutes — say what
  you're about to do and why first.
- **Non-interactive only.** You have no terminal and the key won't allocate one:
  never run TUI commands (`dv tui`, `dv config ai`, `dv ra <agent>` with no
  prompt) — they can't work here.
- **Always `--name`** on actions, so a sibling task switching the selected
  workspace can't redirect your command.
- **One task = one workspace.** Create it, do the work, extract, then
  `dv remove --force` it. Don't accumulate stale containers.
- **Never expose secrets** the dev machine holds (API keys, tokens) into chat.
- **Long operations:** builds, `dv new`, and PR/branch resets run for minutes —
  keep the member informed instead of going quiet.
- **Respect the guard.** A "only `dv` is permitted" refusal is the security
  boundary by design — relay it to the member; don't try to work around it.
