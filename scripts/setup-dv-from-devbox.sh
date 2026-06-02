#!/usr/bin/env bash
#
# Wire the term-llm bot to THIS machine as its `dv` dev box — in ONE command, run
# ON THE DEV BOX (your laptop). Idempotent — safe to re-run.
#
# Use this when term-llm runs on a hosted server (e.g. a DigitalOcean droplet) that
# CANNOT SSH into your dev box — so scripts/setup-dv.sh (which drives the other way,
# server -> dev box) can't run. Here the dev box drives setup over the SSH login you
# already have INTO the server, and nothing ever gives the server admin access to
# this machine: it only ends up with a key locked to `dv` (the forced-command guard
# in term-llm/dv-ssh-guard.py).
#
#   term-llm SERVER (droplet)                 THIS dev box (laptop)
#   • runs `term-llm serve`        ssh        • runs `dv` + Docker + sshd
#   • holds the dv-only PRIVATE   <───────────• you run THIS script here
#     key + `Host dvhost` config  dv-only key • holds the locked authorized_keys
#          ▲  you ssh in to set up ─────────────┘
#
# This script, run here:
#   1. installs the dv skill onto the server (over your ssh login)
#   2. generates the dv-only key ON THE SERVER (private half never leaves it)
#   3. locks THIS box's ~/.ssh/authorized_keys to that key via the guard (local)
#   4. writes the server's ~/.ssh/config so `ssh dvhost` reaches THIS box at its
#      Tailscale name (auto-detected) — correct by construction, no hand-edit
#   5. verifies, from here, that the server can run `dv` AND that a non-`dv`
#      command is refused (the guard is the boundary — prove it guards)
#
# PREREQUISITES on this dev box: Docker installed+running, `dv` installed, an SSH
# server running (macOS: enable Remote Login), and a network path the server can
# use to reach back here — Tailscale recommended (see term-llm/README.md). You also
# need your normal SSH login to the server (the one you use already).
#
# Usage (on the dev box):
#   scripts/setup-dv-from-devbox.sh me@droplet            # me@droplet = your login to the server
#   scripts/setup-dv-from-devbox.sh droplet               # an ssh-config Host alias works too
#   scripts/setup-dv-from-devbox.sh me@droplet --reach-name laptop.tailXXXX.ts.net
#                                                         # address the server should dial back (else auto-detected)
#   scripts/setup-dv-from-devbox.sh me@droplet --new-key  # rotate the dv-only key
#   scripts/setup-dv-from-devbox.sh me@droplet --port 2222        # server SSH port
#   scripts/setup-dv-from-devbox.sh me@droplet --reach-port 2222  # THIS box's sshd port
#
set -euo pipefail

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PLUGIN_DIR="${PLUGIN_DIR:-$HOME/work/second-brain}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/arpitjalan/second-brain/main}"

# --- 0. parse args ------------------------------------------------------------
SERVER_TARGET=""
ALIAS="dvhost"
NEW_KEY=false
REACH_NAME_OVERRIDE=""
PORT_FLAG=""        # --port: laptop -> server SSH port
REACH_PORT="22"     # --reach-port: the port the server dials back to THIS box (sshd)
usage="usage: setup-dv-from-devbox.sh SERVER_TARGET [--reach-name ADDR] [--alias NAME] [--port N] [--reach-port N] [--new-key]
  SERVER_TARGET   your SSH login to the term-llm server: [user@]host, or an ssh-config Host alias"
while [ $# -gt 0 ]; do
  case "$1" in
    --reach-name)   shift; REACH_NAME_OVERRIDE="${1:-}"; [ -n "$REACH_NAME_OVERRIDE" ] || die "--reach-name needs an address" ;;
    --reach-name=*) REACH_NAME_OVERRIDE="${1#--reach-name=}" ;;
    --alias)        shift; ALIAS="${1:-}";               [ -n "$ALIAS" ] || die "--alias needs a name" ;;
    --alias=*)      ALIAS="${1#--alias=}" ;;
    --port)         shift; PORT_FLAG="${1:-}";           [ -n "$PORT_FLAG" ] || die "--port needs a number" ;;
    --port=*)       PORT_FLAG="${1#--port=}" ;;
    --reach-port)   shift; REACH_PORT="${1:-}";          [ -n "$REACH_PORT" ] || die "--reach-port needs a number" ;;
    --reach-port=*) REACH_PORT="${1#--reach-port=}" ;;
    --new-key)      NEW_KEY=true ;;
    -h|--help)      printf '%s\n' "$usage"; exit 0 ;;
    -*)             die "unknown option: $1
$usage" ;;
    *)              [ -z "$SERVER_TARGET" ] || die "unexpected extra argument: $1
$usage"; SERVER_TARGET="$1" ;;
  esac
  shift
done
[ -n "$SERVER_TARGET" ] || die "missing SERVER_TARGET.
$usage"

KEY_NAME="${ALIAS}_ed25519"          # lives at ~/.ssh/$KEY_NAME ON THE SERVER
DEVBOX_USER=$(whoami)                # the user the server will log into this box as
# ssh helper to the server that honours an explicit --port.
sssh() { ssh ${PORT_FLAG:+-p "$PORT_FLAG"} "$@"; }

# --- 0b. work out how the server should reach back to THIS box ----------------
# The dev box is the authority on its own reachable address. Tailscale (recommended)
# gives a stable MagicDNS name; otherwise the operator must say (--reach-name).
detect_reach_name() {
  local ts name ip
  ts=$(command -v tailscale 2>/dev/null || true)
  [ -z "$ts" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ] \
    && ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  [ -n "$ts" ] || return 1
  name=$("$ts" status --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get("Self") or {}).get("DNSName", "").rstrip(".") if d.get("BackendState") == "Running" else "")
except Exception:
    print("")
' 2>/dev/null || true)
  if [ -n "$name" ]; then REACH_NAME="$name"; REACH_HOW="Tailscale MagicDNS"; return 0; fi
  ip=$("$ts" ip -4 2>/dev/null | head -1 || true)
  if [ -n "$ip" ]; then REACH_NAME="$ip"; REACH_HOW="Tailscale IP"; return 0; fi
  return 1
}
say "Working out how the server will reach back to this dev box"
if [ -n "$REACH_NAME_OVERRIDE" ]; then
  REACH_NAME="$REACH_NAME_OVERRIDE"; REACH_HOW="--reach-name"
elif ! detect_reach_name; then
  die "Couldn't auto-detect this box's address. Pass --reach-name ADDR — the address the
  term-llm server can reach THIS dev box at (a stable Tailscale name is ideal). The
  server has to dial back here at runtime, so set up that path first (see Networking
  in term-llm/README.md); a laptop behind NAT isn't reachable without it."
fi
echo "server '$SERVER_TARGET' will reach this box as: $REACH_NAME  ($REACH_HOW), user $DEVBOX_USER, port $REACH_PORT"

# --- 1. reach the server over your normal SSH login ---------------------------
say "Checking your SSH login to the server"
sssh -o ConnectTimeout=10 "$SERVER_TARGET" true \
  || die "Can't reach the term-llm server at '$SERVER_TARGET' over SSH. Use the login you
  normally use to administer it (this script drives setup over that connection)."
echo "reachable."

# --- 2. prerequisites on THIS dev box -----------------------------------------
say "Checking prerequisites on this dev box"
# An SSH server must be listening — the term-llm server connects INTO this box.
if (exec 3<>"/dev/tcp/127.0.0.1/$REACH_PORT") 2>/dev/null; then
  echo "sshd: listening on :$REACH_PORT"
else
  warn "No SSH server answering on 127.0.0.1:$REACH_PORT. The term-llm server connects
      INTO this box, so it needs one. macOS: System Settings -> General -> Sharing ->
      Remote Login (or: sudo systemsetup -setremotelogin on). Linux: start sshd."
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

# --- 3. install the dv skill onto the server ----------------------------------
say "Installing the dv skill onto the server (~/.config/term-llm/skills/dv)"
SKILL_SRC="$PLUGIN_DIR/term-llm/skills/dv/SKILL.md"
sssh "$SERVER_TARGET" 'mkdir -p ~/.config/term-llm/skills/dv'
if [ -f "$SKILL_SRC" ]; then
  sssh "$SERVER_TARGET" 'cat > ~/.config/term-llm/skills/dv/SKILL.md' < "$SKILL_SRC"
  echo "from checkout: $SKILL_SRC"
else
  # No local checkout — fetch on the server (honour GITHUB_TOKEN for a private repo).
  AUTH=""; [ -n "${GITHUB_TOKEN:-}" ] && AUTH="-H \"Authorization: token $GITHUB_TOKEN\""
  sssh "$SERVER_TARGET" "curl -fsSL $AUTH '$RAW_BASE/term-llm/skills/dv/SKILL.md' -o ~/.config/term-llm/skills/dv/SKILL.md" \
    || die "Couldn't fetch the dv skill onto the server. If the repo is private, set GITHUB_TOKEN
  (a PAT with repo read), or run this from a second-brain checkout (set PLUGIN_DIR)."
  echo "fetched on the server from GitHub"
fi
sssh "$SERVER_TARGET" 'grep -q "^name: dv" ~/.config/term-llm/skills/dv/SKILL.md' \
  || die "the dv SKILL.md on the server looks wrong (no 'name: dv'); aborting."
echo "skill installed."

# --- 4. generate the dv-only key ON THE SERVER (private half stays there) ------
say "Generating the dv-only key on the server (~/.ssh/$KEY_NAME)"
[ "$NEW_KEY" = true ] && sssh "$SERVER_TARGET" "rm -f ~/.ssh/$KEY_NAME ~/.ssh/$KEY_NAME.pub"
sssh "$SERVER_TARGET" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { test -f ~/.ssh/$KEY_NAME || ssh-keygen -t ed25519 -f ~/.ssh/$KEY_NAME -N \"\" -C ${ALIAS}-dv >/dev/null; }"
PUBKEY=$(sssh "$SERVER_TARGET" "cat ~/.ssh/$KEY_NAME.pub")
case "$PUBKEY" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) die "couldn't read the dv-only public key from the server (got: ${PUBKEY:0:40})." ;;
esac
echo "key ready on the server (public: ${PUBKEY%% *} …)"

# --- 5. lock THIS box's authorized_keys to that key (via the guard) -----------
# Run the guard's --install locally: it copies itself to ~/.local/bin and adds a
# restrict,command="…" entry for this pubkey. We ignore the ssh-config block it
# prints (step 6 writes the server's config with the right reach address).
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

# --- 6. write the server's ~/.ssh/config so `ssh dvhost` reaches this box ------
say "Writing 'Host $ALIAS' into the server's ~/.ssh/config"
BEGIN="# >>> second-brain dv ($ALIAS) — managed by setup-dv-from-devbox.sh >>>"
END="# <<< second-brain dv ($ALIAS) <<<"
REMOTE_CFG=$(sssh "$SERVER_TARGET" 'cat ~/.ssh/config 2>/dev/null' || true)
# Refuse to clobber a hand-written 'Host <alias>' on the server that we didn't write.
NONMANAGED=$(printf '%s\n' "$REMOTE_CFG" | awk -v a="$ALIAS" -v b="$BEGIN" -v e="$END" '
  $0==b{inblk=1} $0==e{inblk=0; next}
  inblk{next}
  $1=="Host"{for(i=2;i<=NF;i++) if($i==a){print "yes"; exit}}
')
[ -z "$NONMANAGED" ] || die "the server's ~/.ssh/config already has a 'Host $ALIAS' that this
  script didn't write. Rename it there, or run with --alias NAME to use a different alias."
{
  # Existing config minus any previous managed block, then a fresh block.
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
} | sssh "$SERVER_TARGET" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat > ~/.ssh/config && chmod 600 ~/.ssh/config'
echo "wrote managed block for 'Host $ALIAS' on the server."

# --- 7. seed the server's known_hosts for this box (so BatchMode verify works) -
# TOFU: the server trusts this box's host key on first sight. It's the box you're
# setting up; accepting its key here avoids a BatchMode 'host key verification
# failed' at verify. Needs the server to be able to reach this box already.
sssh "$SERVER_TARGET" "ssh-keygen -F $REACH_NAME >/dev/null 2>&1 || ssh-keyscan ${REACH_PORT:+-p $REACH_PORT} -H $REACH_NAME 2>/dev/null >> ~/.ssh/known_hosts" >/dev/null 2>&1 || true

# --- 8. verify, from here, via the server — positively AND negatively ----------
say "Verifying the dv link (server -> this box)"
set +e
VER=$(sssh "$SERVER_TARGET" "ssh -o BatchMode=yes $ALIAS -- dv version" 2>&1); VRC=$?
set -e
if [ "$VRC" -ne 0 ]; then
  echo "$VER" | sed 's/^/  /' >&2
  if printf '%s' "$VER" | grep -qiE 'permission denied|publickey'; then
    die "The server's dv-only key was rejected by this box's sshd. Check this box's
  ~/.ssh/authorized_keys (StrictModes needs ~/.ssh = 700, authorized_keys = 600) and
  that the server logs in as '$DEVBOX_USER'."
  elif printf '%s' "$VER" | grep -qiE 'timed out|refused|no route|not known|unreachable|host key'; then
    die "The server can't reach this box as '$REACH_NAME'. Make sure this box is on the
  network the server uses (Tailscale up on both?), sshd is running here, and the
  reach address is right (re-run with --reach-name <addr> to change it)."
  elif printf '%s' "$VER" | grep -qiE 'dv.*not found|binary not found'; then
    die "Connected and the guard ran, but 'dv' isn't installed on this box (see step 2)."
  else
    die "verification failed (output above)."
  fi
fi
echo "  dv: $(printf '%s' "$VER" | head -1)"

# The guard is the boundary — prove a non-dv command from the server is REFUSED.
if sssh "$SERVER_TARGET" "ssh -o BatchMode=yes $ALIAS -- echo guard-bypass" >/dev/null 2>&1; then
  die "SECURITY: a non-'dv' command was NOT refused — the dv-only guard is being bypassed
  (likely a pre-existing, unrestricted authorized_keys entry on this box for this key).
  Remove that entry so only the 'restrict,command=...' line remains, then re-run."
fi
echo "  guard: non-dv commands are refused (good)."

if sssh "$SERVER_TARGET" "ssh -o BatchMode=yes $ALIAS -- dv list" >/dev/null 2>&1; then
  echo "  docker: dv list works"
else
  warn "dv list failed — Docker on this box may be down. The link is set up; start Docker here."
fi

# --- 9. summary ---------------------------------------------------------------
printf '\n\033[1;32m== dv link ready ==\033[0m\n'
echo "  the bot (on $SERVER_TARGET) runs everything as: ssh $ALIAS -- dv ..."
echo "  reaches this box at:  $REACH_NAME${REACH_PORT:+ (port $REACH_PORT)}, user $DEVBOX_USER"
echo "  dv-only key:          ~/.ssh/$KEY_NAME on the server (private half stays there)"
printf '\n  This box must be AWAKE and on the network for the bot to use it.\n'
echo "  Then restart 'term-llm serve' on the server so it scans the new skill."
