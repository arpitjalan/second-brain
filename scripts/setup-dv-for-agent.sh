#!/usr/bin/env bash
#
# Give ONE term-llm agent `dv` access, when term-llm runs as PER-AGENT CONTAINERS
# (`term-llm contain`) — in ONE command, run ON THE DEV BOX (this machine).
# Idempotent — safe to re-run.
#
# Why this exists (vs scripts/setup-dv-from-devbox.sh): that script assumes
# `term-llm serve` is a HOST process and installs the skill + dv-only key into the
# SSH-login user's home (~/.config/term-llm/skills, ~/.ssh). But in a containerised
# deployment each agent runs in its own container (`term-llm-contain-<agent>-app-1`)
# with its own `/home/agent` VOLUME, and reads skills + ssh config from THERE — it
# never looks at the login user's home. So the host-home script would report success
# while granting NO agent dv. This script installs INTO a specific agent's container
# volume instead, so dv is scoped to exactly the agent(s) you choose (least
# privilege: only the dev-facing bot can spin up dev containers on this box).
#
#   term-llm SERVER (droplet)                     THIS dev box (laptop)
#   ┌───────────────────────────────┐  ssh   ┌───────────────────────────┐
#   │ docker: term-llm-contain-      │ ─────► │ runs `dv` + Docker + sshd │
#   │   <agent>-app-1  (one volume   │ dv-only│ holds the locked          │
#   │   /home/agent per agent)       │  key   │ authorized_keys (guard)   │
#   │ the chosen agent holds the     │        │ you run THIS script here  │
#   │ dv-only key in ITS volume      │ ◄──────┤                           │
#   └───────────────────────────────┘ dv runs └───────────────────────────┘
#
# This script, run here:
#   1. installs the dv skill into the agent's container volume
#        (<agent-home>/.config/term-llm/skills/dv), owned by the agent user
#   2. generates the dv-only key INSIDE the container (private half never leaves it)
#   3. locks THIS box's ~/.ssh/authorized_keys to that key via the guard (local)
#   4. writes a `Host dvhost` block into the agent's in-container ~/.ssh/config so
#      `ssh dvhost` reaches THIS box at its Tailscale address (auto-detected)
#   5. verifies, from inside the container, that the agent can run `dv` AND that a
#      non-`dv` command is refused (the guard is the boundary — prove it guards)
#   6. restarts the agent (`term-llm contain restart <agent>`) so serve rescans skills
#
# PREREQUISITES on this dev box: Docker installed+running, `dv` installed, an SSH
# server running (the bot's container connects INTO this box — Linux: enable sshd,
# ideally bound to Tailscale only; see term-llm/README.md), and a network path the
# container can use to reach back here — Tailscale recommended (both the server and
# this box on the tailnet; Docker NATs the container out through the host's tailnet).
# You also need your normal SSH login to the server.
#
# Usage (on the dev box):
#   scripts/setup-dv-for-agent.sh jarvis me@droplet         # agent + your login to the server
#   scripts/setup-dv-for-agent.sh jarvis droplet            # an ssh-config Host alias works too
#   scripts/setup-dv-for-agent.sh jarvis me@droplet --reach-name laptop.tailXXXX.ts.net
#   scripts/setup-dv-for-agent.sh jarvis me@droplet --container term-llm-contain-jarvis-app-1
#   scripts/setup-dv-for-agent.sh jarvis me@droplet --new-key      # rotate the dv-only key
#   scripts/setup-dv-for-agent.sh jarvis me@droplet --no-restart   # skip the term-llm contain restart
#   scripts/setup-dv-for-agent.sh jarvis me@droplet --agent-user agent --agent-home /home/agent
#
set -euo pipefail

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PLUGIN_DIR="${PLUGIN_DIR:-$HOME/work/second-brain}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/arpitjalan/second-brain/main}"

# --- 0. parse args ------------------------------------------------------------
AGENT=""
SERVER_TARGET=""
ALIAS="dvhost"
CONTAINER=""              # default derived from AGENT below
AGENT_USER="agent"        # the user term-llm serve runs as inside the container
AGENT_HOME="/home/agent"  # that user's home (the persistent volume mount)
NEW_KEY=false
NO_RESTART=false
REACH_NAME_OVERRIDE=""
PORT_FLAG=""              # --port: laptop -> server SSH port
REACH_PORT="22"          # --reach-port: the port the container dials back to THIS box (sshd)
usage="usage: setup-dv-for-agent.sh AGENT SERVER_TARGET [--container NAME] [--reach-name ADDR]
       [--alias NAME] [--agent-user USER] [--agent-home DIR] [--port N] [--reach-port N]
       [--new-key] [--no-restart]
  AGENT          the term-llm agent/workspace to grant dv (e.g. jarvis)
  SERVER_TARGET  your SSH login to the term-llm server: [user@]host, or an ssh-config alias"
while [ $# -gt 0 ]; do
  case "$1" in
    --container)     shift; CONTAINER="${1:-}";          [ -n "$CONTAINER" ]   || die "--container needs a name" ;;
    --container=*)   CONTAINER="${1#--container=}" ;;
    --reach-name)    shift; REACH_NAME_OVERRIDE="${1:-}"; [ -n "$REACH_NAME_OVERRIDE" ] || die "--reach-name needs an address" ;;
    --reach-name=*)  REACH_NAME_OVERRIDE="${1#--reach-name=}" ;;
    --alias)         shift; ALIAS="${1:-}";              [ -n "$ALIAS" ]       || die "--alias needs a name" ;;
    --alias=*)       ALIAS="${1#--alias=}" ;;
    --agent-user)    shift; AGENT_USER="${1:-}";         [ -n "$AGENT_USER" ]  || die "--agent-user needs a name" ;;
    --agent-user=*)  AGENT_USER="${1#--agent-user=}" ;;
    --agent-home)    shift; AGENT_HOME="${1:-}";         [ -n "$AGENT_HOME" ]  || die "--agent-home needs a path" ;;
    --agent-home=*)  AGENT_HOME="${1#--agent-home=}" ;;
    --port)          shift; PORT_FLAG="${1:-}";          [ -n "$PORT_FLAG" ]   || die "--port needs a number" ;;
    --port=*)        PORT_FLAG="${1#--port=}" ;;
    --reach-port)    shift; REACH_PORT="${1:-}";         [ -n "$REACH_PORT" ]  || die "--reach-port needs a number" ;;
    --reach-port=*)  REACH_PORT="${1#--reach-port=}" ;;
    --new-key)       NEW_KEY=true ;;
    --no-restart)    NO_RESTART=true ;;
    -h|--help)       printf '%s\n' "$usage"; exit 0 ;;
    -*)              die "unknown option: $1
$usage" ;;
    *)               if [ -z "$AGENT" ]; then AGENT="$1"
                     elif [ -z "$SERVER_TARGET" ]; then SERVER_TARGET="$1"
                     else die "unexpected extra argument: $1
$usage"; fi ;;
  esac
  shift
done
[ -n "$AGENT" ]         || die "missing AGENT.
$usage"
[ -n "$SERVER_TARGET" ] || die "missing SERVER_TARGET.
$usage"
CONTAINER="${CONTAINER:-term-llm-contain-${AGENT}-app-1}"

KEY_NAME="${ALIAS}_ed25519"     # lives at $AGENT_HOME/.ssh/$KEY_NAME INSIDE the container
DEVBOX_USER=$(whoami)           # the user the container will log into this box as
# ssh helper to the server that honours an explicit --port.
sssh() { ssh ${PORT_FLAG:+-p "$PORT_FLAG"} "$@"; }
# run a command inside the agent's container as the agent user (HOME set so ssh/~
# resolve to the volume, not the docker-exec default of /root).
dexec() { sssh "$SERVER_TARGET" "docker exec -u $AGENT_USER -e HOME=$AGENT_HOME $CONTAINER $*"; }
# same, but pipe local stdin into the container (skill/config writes -> agent-owned).
dexec_in() { sssh "$SERVER_TARGET" "docker exec -i -u $AGENT_USER -e HOME=$AGENT_HOME $CONTAINER $*"; }

# --- 0b. work out how the container should reach back to THIS box --------------
# Containers don't share the host tailnet directly, but Docker NATs their outbound
# traffic through the host's tailscale0, so a stable Tailscale IP works from inside
# the container. We default to the IPv4 (robust — no in-container MagicDNS needed);
# pass --reach-name to use a MagicDNS name or any other reachable address.
detect_reach_name() {
  local ts ip name
  ts=$(command -v tailscale 2>/dev/null || true)
  [ -z "$ts" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ] \
    && ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  [ -n "$ts" ] || return 1
  ip=$("$ts" ip -4 2>/dev/null | head -1 || true)
  if [ -n "$ip" ]; then REACH_NAME="$ip"; REACH_HOW="Tailscale IP"; return 0; fi
  name=$("$ts" status --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get("Self") or {}).get("DNSName", "").rstrip(".") if d.get("BackendState") == "Running" else "")
except Exception:
    print("")
' 2>/dev/null || true)
  if [ -n "$name" ]; then REACH_NAME="$name"; REACH_HOW="Tailscale MagicDNS"; return 0; fi
  return 1
}
say "Working out how the '$AGENT' container will reach back to this dev box"
if [ -n "$REACH_NAME_OVERRIDE" ]; then
  REACH_NAME="$REACH_NAME_OVERRIDE"; REACH_HOW="--reach-name"
elif ! detect_reach_name; then
  die "Couldn't auto-detect this box's address. Pass --reach-name ADDR — the address the
  agent's container can reach THIS dev box at (a stable Tailscale IP/name is ideal).
  The container dials back here at runtime, so set up that path first (Networking in
  term-llm/README.md); a laptop behind NAT isn't reachable without it."
fi
echo "agent '$AGENT' (container $CONTAINER) will reach this box as: $REACH_NAME  ($REACH_HOW), user $DEVBOX_USER, port $REACH_PORT"

# --- 1. reach the server over your normal SSH login ---------------------------
say "Checking your SSH login to the server"
sssh -o ConnectTimeout=10 "$SERVER_TARGET" true \
  || die "Can't reach the term-llm server at '$SERVER_TARGET' over SSH. Use the login you
  normally use to administer it (this script drives setup over that connection)."
echo "reachable."

# --- 1b. the agent's container must be running --------------------------------
sssh "$SERVER_TARGET" "docker ps --format '{{.Names}}' | grep -qx '$CONTAINER'" \
  || die "container '$CONTAINER' isn't running on the server. List agents with
  'term-llm contain ls' (or 'docker ps'); pass --container NAME if it differs from
  the default 'term-llm-contain-<agent>-app-1'."
echo "container '$CONTAINER' is running."

# --- 2. prerequisites on THIS dev box -----------------------------------------
say "Checking prerequisites on this dev box"
if (exec 3<>"/dev/tcp/127.0.0.1/$REACH_PORT") 2>/dev/null; then
  echo "sshd: listening on :$REACH_PORT"
else
  warn "No SSH server answering on 127.0.0.1:$REACH_PORT. The agent's container connects
      INTO this box, so it needs one (ideally bound to Tailscale only — see
      term-llm/README.md). Linux: enable sshd; macOS: Settings -> General -> Sharing ->
      Remote Login."
fi
if command -v dv >/dev/null 2>&1 || [ -x "$HOME/.local/bin/dv" ]; then
  echo "dv: installed"
else
  warn "dv is NOT installed here. Install it (installs the dv binary only):
      curl -sSfL https://raw.githubusercontent.com/discourse/dv/main/install.sh | sh"
fi
if docker info >/dev/null 2>&1; then
  echo "Docker: running"
else
  warn "Docker isn't running here (or your user can't reach it). dv needs it — install.sh
      does NOT install Docker; install/start Docker first."
fi

# --- 3. install the dv skill into the agent's container volume ----------------
say "Installing the dv skill into $CONTAINER:$AGENT_HOME/.config/term-llm/skills/dv"
SKILL_SRC="$PLUGIN_DIR/term-llm/skills/dv/SKILL.md"
SKILL_TMP=""
if [ ! -f "$SKILL_SRC" ]; then
  # No local checkout — fetch locally (honour GITHUB_TOKEN for a private repo), then
  # pipe the content into the container so it lands owned by the agent user.
  SKILL_TMP="$(mktemp)"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: token $GITHUB_TOKEN" "$RAW_BASE/term-llm/skills/dv/SKILL.md" -o "$SKILL_TMP"
  else
    curl -fsSL "$RAW_BASE/term-llm/skills/dv/SKILL.md" -o "$SKILL_TMP"
  fi || { rm -f "$SKILL_TMP"; die "Couldn't fetch the dv skill from GitHub. If the repo is private,
  set GITHUB_TOKEN (a PAT with repo read), or run from a second-brain checkout (set PLUGIN_DIR)."; }
  SKILL_SRC="$SKILL_TMP"
fi
dexec_in "sh -c 'mkdir -p $AGENT_HOME/.config/term-llm/skills/dv && cat > $AGENT_HOME/.config/term-llm/skills/dv/SKILL.md'" < "$SKILL_SRC"
[ -n "$SKILL_TMP" ] && rm -f "$SKILL_TMP"
dexec "grep -q '^name: dv' $AGENT_HOME/.config/term-llm/skills/dv/SKILL.md" \
  || die "the dv SKILL.md in the container looks wrong (no 'name: dv'); aborting."
echo "skill installed."

# --- 3b. install a `dv` wrapper on the container PATH -------------------------
# The bot's model tends to run `dv …` directly in its shell rather than the explicit
# `ssh dvhost -- dv …` the skill teaches — and a bare `dv` isn't installed in the
# container, so it fails. Install a thin wrapper at /usr/local/bin/dv that forwards
# to the guard-locked dvhost, so the natural `dv …` invocation just works with no
# reliance on the model activating the skill. The guard still limits it to dv-only.
# NB: /usr/local/bin is in the image layer, so it survives `term-llm contain restart`
# but NOT `rebuild`/`rm` — re-run this script after either (it's idempotent).
say "Installing the dv wrapper on the container PATH (/usr/local/bin/dv -> ssh $ALIAS -- dv)"
WRAPPER_SRC="$PLUGIN_DIR/term-llm/dv-wrapper.sh"
WRAPPER_TMP=""
if [ ! -f "$WRAPPER_SRC" ]; then
  WRAPPER_TMP="$(mktemp)"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: token $GITHUB_TOKEN" "$RAW_BASE/term-llm/dv-wrapper.sh" -o "$WRAPPER_TMP"
  else
    curl -fsSL "$RAW_BASE/term-llm/dv-wrapper.sh" -o "$WRAPPER_TMP"
  fi || { rm -f "$WRAPPER_TMP"; die "Couldn't fetch dv-wrapper.sh from GitHub (see the GITHUB_TOKEN note above)."; }
  WRAPPER_SRC="$WRAPPER_TMP"
fi
# Substitute the alias/home placeholders, then drop it in as the agent's `dv`.
sed -e "s|@HOME@|$AGENT_HOME|g" -e "s|@ALIAS@|$ALIAS|g" "$WRAPPER_SRC" \
  | sssh "$SERVER_TARGET" "docker exec -i -u root $CONTAINER sh -c 'cat > /usr/local/bin/dv && chmod 755 /usr/local/bin/dv'"
[ -n "$WRAPPER_TMP" ] && rm -f "$WRAPPER_TMP"
if dexec "command -v dv" >/dev/null 2>&1; then
  echo "wrapper installed and 'dv' is on the agent's PATH."
else
  warn "wrapper written to /usr/local/bin/dv but 'dv' isn't resolving on the agent's PATH —
      check the container's PATH (the model needs a bare 'dv' to work)."
fi

# --- 4. generate the dv-only key INSIDE the container -------------------------
say "Generating the dv-only key inside the container ($AGENT_HOME/.ssh/$KEY_NAME)"
[ "$NEW_KEY" = true ] && dexec "rm -f $AGENT_HOME/.ssh/$KEY_NAME $AGENT_HOME/.ssh/$KEY_NAME.pub"
dexec "sh -c 'mkdir -p $AGENT_HOME/.ssh && chmod 700 $AGENT_HOME/.ssh && { test -f $AGENT_HOME/.ssh/$KEY_NAME || ssh-keygen -t ed25519 -f $AGENT_HOME/.ssh/$KEY_NAME -N \"\" -C ${AGENT}-dv >/dev/null; }'"
PUBKEY=$(dexec "cat $AGENT_HOME/.ssh/$KEY_NAME.pub")
case "$PUBKEY" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) die "couldn't read the dv-only public key from the container (got: ${PUBKEY:0:40})." ;;
esac
echo "key ready in the container (public: ${PUBKEY%% *} …)"

# --- 5. lock THIS box's authorized_keys to that key (via the guard) -----------
say "Locking this box's authorized_keys to the dv-only key"
GUARD_SRC="$PLUGIN_DIR/term-llm/dv-ssh-guard.py"
GUARD_TMP=""
if [ ! -f "$GUARD_SRC" ]; then
  GUARD_TMP="$(mktemp)"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: token $GITHUB_TOKEN" "$RAW_BASE/term-llm/dv-ssh-guard.py" -o "$GUARD_TMP"
  else
    curl -fsSL "$RAW_BASE/term-llm/dv-ssh-guard.py" -o "$GUARD_TMP"
  fi || die "Couldn't fetch dv-ssh-guard.py from GitHub (see the GITHUB_TOKEN note above)."
  GUARD_SRC="$GUARD_TMP"
fi
INSTALL_OUT=$(python3 "$GUARD_SRC" --install "$PUBKEY" 2>&1) || {
  printf '%s\n' "$INSTALL_OUT" | sed 's/^/  /' >&2
  [ -n "$GUARD_TMP" ] && rm -f "$GUARD_TMP"
  die "the guard installer failed on this box (output above)."
}
[ -n "$GUARD_TMP" ] && rm -f "$GUARD_TMP"
printf '%s\n' "$INSTALL_OUT" | grep -Ei 'wrote|already|guard installed' | sed 's/^/  /' || true

# --- 6. write the agent's in-container ~/.ssh/config (Host dvhost) -------------
say "Writing 'Host $ALIAS' into $CONTAINER:$AGENT_HOME/.ssh/config"
BEGIN="# >>> second-brain dv ($ALIAS) — managed by setup-dv-for-agent.sh >>>"
END="# <<< second-brain dv ($ALIAS) <<<"
REMOTE_CFG=$(dexec "sh -c 'cat $AGENT_HOME/.ssh/config 2>/dev/null'" || true)
# Refuse to clobber a hand-written 'Host <alias>' in the container we didn't write.
NONMANAGED=$(printf '%s\n' "$REMOTE_CFG" | awk -v a="$ALIAS" -v b="$BEGIN" -v e="$END" '
  $0==b{inblk=1} $0==e{inblk=0; next}
  inblk{next}
  $1=="Host"{for(i=2;i<=NF;i++) if($i==a){print "yes"; exit}}
')
[ -z "$NONMANAGED" ] || die "the container's ~/.ssh/config already has a 'Host $ALIAS' that this
  script didn't write. Rename it there, or run with --alias NAME to use a different alias."
{
  if [ -n "$REMOTE_CFG" ]; then
    printf '%s\n' "$REMOTE_CFG" | awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} skip==0{print} $0==e{skip=0}'
  fi
  printf '%s\n' "$BEGIN"
  printf 'Host %s\n'             "$ALIAS"
  printf '    HostName %s\n'     "$REACH_NAME"
  printf '    User %s\n'         "$DEVBOX_USER"
  [ "$REACH_PORT" != 22 ] && printf '    Port %s\n' "$REACH_PORT"
  printf '    IdentityFile ~/.ssh/%s\n' "$KEY_NAME"
  printf '    IdentitiesOnly yes\n'
  printf '%s\n' "$END"
} | dexec_in "sh -c 'mkdir -p $AGENT_HOME/.ssh && chmod 700 $AGENT_HOME/.ssh && cat > $AGENT_HOME/.ssh/config && chmod 600 $AGENT_HOME/.ssh/config'"
echo "wrote managed block for 'Host $ALIAS' in the container."

# --- 7. seed the container's known_hosts for this box (BatchMode verify) -------
dexec "sh -c 'ssh-keygen -F $REACH_NAME -f $AGENT_HOME/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan ${REACH_PORT:+-p $REACH_PORT} -H $REACH_NAME 2>/dev/null >> $AGENT_HOME/.ssh/known_hosts'" >/dev/null 2>&1 || true

# --- 8. verify, from inside the container — positively AND negatively ----------
say "Verifying the dv link (container -> this box)"
set +e
VER=$(dexec "ssh -o BatchMode=yes $ALIAS -- dv version" 2>&1); VRC=$?
set -e
if [ "$VRC" -ne 0 ]; then
  echo "$VER" | sed 's/^/  /' >&2
  if printf '%s' "$VER" | grep -qiE 'permission denied|publickey'; then
    die "The container's dv-only key was rejected by this box's sshd. Check this box's
  ~/.ssh/authorized_keys (StrictModes needs ~/.ssh = 700, authorized_keys = 600) and
  that the container logs in as '$DEVBOX_USER'."
  elif printf '%s' "$VER" | grep -qiE 'timed out|refused|no route|not known|unreachable|host key'; then
    die "The container can't reach this box as '$REACH_NAME'. Make sure both the server and
  this box are on the tailnet, sshd is running here, and the reach address is right
  (re-run with --reach-name <addr> to change it)."
  elif printf '%s' "$VER" | grep -qiE 'dv.*not found|binary not found'; then
    die "Connected and the guard ran, but 'dv' isn't installed on this box (see step 2)."
  else
    die "verification failed (output above)."
  fi
fi
echo "  dv: $(printf '%s' "$VER" | grep -i '^dv version' | head -1)"

# The guard is the boundary — prove a non-dv command from the container is REFUSED.
if dexec "ssh -o BatchMode=yes $ALIAS -- echo guard-bypass" >/dev/null 2>&1; then
  die "SECURITY: a non-'dv' command was NOT refused — the dv-only guard is being bypassed
  (likely a pre-existing, unrestricted authorized_keys entry on this box for this key).
  Remove that entry so only the 'restrict,command=...' line remains, then re-run."
fi
echo "  guard: non-dv commands are refused (good)."

if dexec "ssh -o BatchMode=yes $ALIAS -- dv list" >/dev/null 2>&1; then
  echo "  docker: dv list works"
else
  warn "dv list failed — Docker on this box may be down. The link is set up; start Docker here."
fi

# Confirm the bare `dv` wrapper (what the model actually types) resolves and works.
if dexec "dv version" 2>/dev/null | grep -qi '^dv version'; then
  echo "  wrapper: bare 'dv version' works (the model's natural invocation)"
else
  warn "the bare 'dv' wrapper didn't return a version — the model's 'dv …' calls may fail
      even though 'ssh $ALIAS -- dv' works. Check /usr/local/bin/dv in the container."
fi

# --- 9. restart the agent so term-llm serve rescans skills --------------------
if [ "$NO_RESTART" = true ]; then
  warn "skipping restart (--no-restart). Run 'term-llm contain restart $AGENT' on the server
      so serve discovers the dv skill."
else
  say "Restarting agent '$AGENT' so term-llm rescans skills"
  if sssh "$SERVER_TARGET" "command -v term-llm >/dev/null 2>&1"; then
    sssh "$SERVER_TARGET" "term-llm contain restart $AGENT" && echo "restarted via 'term-llm contain restart $AGENT'."
  else
    sssh "$SERVER_TARGET" "docker restart $CONTAINER" >/dev/null && echo "restarted via 'docker restart $CONTAINER' (term-llm CLI not on PATH)."
  fi
fi

# --- 10. summary --------------------------------------------------------------
printf '\n\033[1;32m== %s now has dv ==\033[0m\n' "$AGENT"
echo "  the agent runs a bare 'dv …' in $CONTAINER (wrapper -> ssh $ALIAS -- dv …)"
echo "  reaches this box at:  $REACH_NAME${REACH_PORT:+ (port $REACH_PORT)}, user $DEVBOX_USER"
echo "  dv-only key:          $AGENT_HOME/.ssh/$KEY_NAME inside the container (private half stays there)"
echo "  other agents are unaffected — dv is scoped to '$AGENT' only."
printf '\n  This box must be AWAKE and on the network for the agent to use it.\n'
echo "  Test it in the forum: ask '$AGENT' to run \`dv list\` or spin up a dev container."
