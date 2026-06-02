#!/usr/bin/env bash
#
# Wire the term-llm bot to a `dv` (Discourse Vibe) dev machine — in ONE command,
# run ON THE TERM-LLM SERVER. Idempotent — safe to re-run.
#
# `dv` has no remote mode: it only drives the local Docker on whatever box it runs
# on. So the bot reaches a separate dev machine over SSH using a key locked to `dv`
# and nothing else (the forced-command guard in term-llm/dv-ssh-guard.py). Setting
# that up by hand is 4 steps across 2 machines with two clipboard hops and a
# hand-edited HostName that is usually wrong behind Tailscale/NAT. This script does
# the whole thing from the server, over your OWN (admin) SSH login to the dev box:
#
#   1. installs the dv skill into ~/.config/term-llm/skills/dv/
#   2. mints the dv-only SSH key (reuses an existing one unless --new-key)
#   3. scp's the guard to the dev box and runs its self-installer there, so the
#      bot's PUBLIC key travels as an argument — never copy/pasted by hand
#   4. writes the `Host dvhost` block into ~/.ssh/config locally, with
#      HostName = the address you just reached the dev box at — correct by
#      construction, no hand-edit, even behind Tailscale/NAT
#   5. checks dv + Docker are present on the dev box (over your admin SSH)
#   6. verifies the locked key BOTH ways: `dv` works, AND a non-`dv` command is
#      refused (the guard is the security boundary — prove it actually guards)
#
# It uses your admin SSH only as a SETUP-TIME bootstrap to *write* the restriction;
# the bot only ever holds the dv-only key. The resulting authorized_keys entry is
# byte-identical to a hand-made one, so the guard is exactly as strong.
#
# Usage (on the term-llm server):
#   scripts/setup-dv.sh me@devbox                 # me@devbox = your normal login to the dev box
#   scripts/setup-dv.sh devbox                    # an ssh-config Host alias works too
#   scripts/setup-dv.sh me@devbox --new-key       # rotate the dv-only key
#   scripts/setup-dv.sh me@devbox --host-name devbox.tailXXXX.ts.net
#                                                 # bake a different reach address than you SSH'd in over
#   scripts/setup-dv.sh me@devbox --port 2222     # non-default SSH port for a plain host
#   scripts/setup-dv.sh me@devbox --alias dvhost2 # a second dev box / a second key+alias
#
# The dev machine must be AWAKE and reachable, with Docker installed+running and
# `dv` installed (see term-llm/README.md). Private repo? export GITHUB_TOKEN=... so
# the skill/guard can be fetched from GitHub when no local checkout is present.
#
set -euo pipefail

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PLUGIN_DIR="${PLUGIN_DIR:-$HOME/work/second-brain}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/arpitjalan/second-brain/main}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.config/term-llm/skills}"

# --- 0. parse args ------------------------------------------------------------
DEV_TARGET=""
ALIAS="dvhost"
NEW_KEY=false
HOST_NAME_OVERRIDE=""
DEV_PORT_FLAG=""     # only set by --port; an ssh-config alias carries its own port
usage="usage: setup-dv.sh DEV_TARGET [--alias NAME] [--host-name ADDR] [--port N] [--new-key]
  DEV_TARGET   how THIS server reaches the dev box: [user@]host, or an ssh-config Host alias"
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)       shift; ALIAS="${1:-}";              [ -n "$ALIAS" ] || die "--alias needs a name" ;;
    --alias=*)     ALIAS="${1#--alias=}" ;;
    --host-name)   shift; HOST_NAME_OVERRIDE="${1:-}";  [ -n "$HOST_NAME_OVERRIDE" ] || die "--host-name needs an address" ;;
    --host-name=*) HOST_NAME_OVERRIDE="${1#--host-name=}" ;;
    --port)        shift; DEV_PORT_FLAG="${1:-}";       [ -n "$DEV_PORT_FLAG" ] || die "--port needs a number" ;;
    --port=*)      DEV_PORT_FLAG="${1#--port=}" ;;
    --new-key)     NEW_KEY=true ;;
    -h|--help)     printf '%s\n' "$usage"; exit 0 ;;
    -*)            die "unknown option: $1
$usage" ;;
    *)             [ -z "$DEV_TARGET" ] || die "unexpected extra argument: $1
$usage"; DEV_TARGET="$1" ;;
  esac
  shift
done
[ -n "$DEV_TARGET" ] || die "missing DEV_TARGET.
$usage"

KEY="$HOME/.ssh/${ALIAS}_ed25519"

# Resolve how the bot will reach the dev box. `ssh -G` expands ssh-config aliases
# and fills in the effective hostname/user/port WITHOUT connecting — so the value
# we bake into HostName is exactly the address SSH itself would dial, which is the
# whole point (no more os.uname().nodename guess from the dev box's vantage point).
say "Resolving how the bot will reach '$DEV_TARGET'"
G=$(ssh -G ${DEV_PORT_FLAG:+-p "$DEV_PORT_FLAG"} "$DEV_TARGET" 2>/dev/null) \
  || die "ssh could not parse target '$DEV_TARGET' (need [user@]host or an ssh-config Host alias)."
DEV_HOST=$(printf '%s\n' "$G" | awk '$1=="hostname"{print $2; exit}')
DEV_USER=$(printf '%s\n' "$G" | awk '$1=="user"{print $2; exit}')
DEV_PORT=$(printf '%s\n' "$G" | awk '$1=="port"{print $2; exit}')
CFG_HOSTNAME="${HOST_NAME_OVERRIDE:-$DEV_HOST}"
[ -n "$CFG_HOSTNAME" ] || die "could not determine a HostName for '$DEV_TARGET'."
echo "target=$DEV_TARGET  ->  HostName=$CFG_HOSTNAME  User=${DEV_USER:-<default>}  Port=${DEV_PORT:-22}  alias=$ALIAS"

# ssh/scp helpers that honour an explicit --port (an alias resolves its own port).
dssh() { ssh ${DEV_PORT_FLAG:+-p "$DEV_PORT_FLAG"} "$@"; }
dscp() { scp ${DEV_PORT_FLAG:+-P "$DEV_PORT_FLAG"} "$@"; }

# --- 1. reach the dev box over your admin SSH ---------------------------------
# This is the bootstrap channel. The first connect to an unknown host will ask you
# to confirm its key — accept it (we never disable host-key checking). It also
# seeds known_hosts for the dvhost alias, which resolves to the same HostName.
say "Checking the dev machine is reachable over your SSH login"
dssh -o ConnectTimeout=10 "$DEV_TARGET" true \
  || die "Can't reach '$DEV_TARGET' over SSH. Is the dev box awake and on the network,
  and do you have your normal (admin) SSH login to it? (This script bootstraps the
  dv-only key using YOUR access; it can't create access it doesn't have.)"
echo "reachable."

# --- 2. install the dv skill locally ------------------------------------------
say "Installing the dv skill into $SKILLS_DIR/dv"
mkdir -p "$SKILLS_DIR/dv"
SKILL_DEST="$SKILLS_DIR/dv/SKILL.md"
SKILL_SRC="$PLUGIN_DIR/term-llm/skills/dv/SKILL.md"
if [ -f "$SKILL_SRC" ]; then
  cp "$SKILL_SRC" "$SKILL_DEST"
  echo "from checkout: $SKILL_SRC"
else
  fetch() { # url dest — honour GITHUB_TOKEN for a private repo
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: token $GITHUB_TOKEN" "$1" -o "$2"
    else
      curl -fsSL "$1" -o "$2"
    fi
  }
  # -fsSL fails (no body) on a private raw URL without a token — catch it loudly
  # rather than leaving an empty/missing SKILL.md the bot would silently ignore.
  fetch "$RAW_BASE/term-llm/skills/dv/SKILL.md" "$SKILL_DEST" \
    || die "Couldn't fetch the dv skill from GitHub. If the repo is private, set GITHUB_TOKEN
  (a PAT with repo read), or run this from a second-brain checkout (set PLUGIN_DIR)."
  echo "from GitHub: $RAW_BASE/term-llm/skills/dv/SKILL.md"
fi
grep -q '^name: dv' "$SKILL_DEST" || die "the fetched dv SKILL.md looks wrong (no 'name: dv'); aborting."
echo "skill installed ($(wc -c < "$SKILL_DEST" | tr -d ' ') bytes)"
command -v term-llm >/dev/null 2>&1 && term-llm skills validate dv >/dev/null 2>&1 \
  && echo "term-llm validated the skill"

# --- 3. mint (or reuse) the dv-only SSH key -----------------------------------
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [ -f "$KEY" ] && [ "$NEW_KEY" = false ]; then
  say "Reusing the existing dv-only key ($KEY). Pass --new-key to rotate."
else
  say "Minting a dv-only SSH key ($KEY)"
  [ "$NEW_KEY" = true ] && rm -f "$KEY" "$KEY.pub"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${ALIAS}-dv" >/dev/null
  echo "created."
fi
PUBKEY=$(cat "$KEY.pub")   # public half only; the private key never leaves the server

# --- 4. push + self-install the guard on the dev box --------------------------
# The guard's --install takes the pubkey as an argument, so it rides over the admin
# SSH — no clipboard hop. We ignore the ssh-config block it prints (step 5 writes
# the correct one locally). dv-ssh-guard.py refuses a piped/stdin install, so scp
# it to a file first, then run + clean up.
say "Installing the dv-only guard on the dev box"
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
dssh "$DEV_TARGET" 'mkdir -p ~/.local/bin'
dscp "$GUARD_SRC" "$DEV_TARGET:/tmp/dv-ssh-guard.py"
[ -n "$GUARD_TMP" ] && rm -f "$GUARD_TMP"
# Capture the installer's output: it self-copies into ~/.local/bin, adds the
# restrict,command authorized_keys entry, and reports dv's presence.
INSTALL_OUT=$(dssh "$DEV_TARGET" python3 /tmp/dv-ssh-guard.py --install "'$PUBKEY'" 2>&1) || {
  printf '%s\n' "$INSTALL_OUT" | sed 's/^/  /' >&2
  dssh "$DEV_TARGET" rm -f /tmp/dv-ssh-guard.py >/dev/null 2>&1 || true
  die "the guard installer failed on the dev box (output above)."
}
dssh "$DEV_TARGET" rm -f /tmp/dv-ssh-guard.py >/dev/null 2>&1 || true
printf '%s\n' "$INSTALL_OUT" | grep -Ei 'added|already|guard installed' | sed 's/^/  /' || true

# --- 5. check the dev box has dv + Docker (over admin SSH) --------------------
# The admin key CAN run arbitrary commands (unlike the locked key), so probe the
# real prerequisites here and warn early instead of failing cryptically at runtime.
say "Checking prerequisites on the dev box"
# Force POSIX sh (the dev box's login shell may be fish/zsh) and look for dv on PATH
# OR in ~/.local/bin (dv's default home, not always on a non-login PATH). $HOME is
# expanded by the remote shell, so it resolves to the dev user's home.
PREREQ=$(dssh "$DEV_TARGET" 'sh -c "command -v dv >/dev/null 2>&1 || [ -x $HOME/.local/bin/dv ] && echo DV_OK; docker info >/dev/null 2>&1 && echo DOCKER_OK"' 2>/dev/null || true)
case "$PREREQ" in *DV_OK*) echo "dv: installed" ;; *)
  warn "dv is NOT installed on the dev box. Install it (installs the dv binary only):
      curl -sSfL https://raw.githubusercontent.com/discourse/dv/main/install.sh | sh" ;;
esac
case "$PREREQ" in *DOCKER_OK*) echo "Docker: running" ;; *)
  warn "Docker isn't running on the dev box (or your user can't reach it). dv needs it.
      install.sh does NOT install Docker — install/start Docker and add your user to the 'docker' group." ;;
esac

# --- 6. write the Host alias into ~/.ssh/config (HostName correct here) --------
say "Writing 'Host $ALIAS' into ~/.ssh/config"
CFG="$HOME/.ssh/config"
BEGIN="# >>> second-brain dv ($ALIAS) — managed by setup-dv.sh >>>"
END="# <<< second-brain dv ($ALIAS) <<<"
touch "$CFG"; chmod 600 "$CFG"
# Refuse to clobber a hand-written 'Host <alias>' that we didn't put there.
NONMANAGED=$(awk -v a="$ALIAS" -v b="$BEGIN" -v e="$END" '
  $0==b{inblk=1} $0==e{inblk=0; next}
  inblk{next}
  $1=="Host"{for(i=2;i<=NF;i++) if($i==a){print "yes"; exit}}
' "$CFG")
[ -z "$NONMANAGED" ] || die "$CFG already has a 'Host $ALIAS' that setup-dv.sh didn't write.
  Rename it, or run with --alias NAME to use a different alias."
# Drop any previous managed block (inclusive of the fences), then append a fresh one.
awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} skip==0{print} $0==e{skip=0}' "$CFG" > "$CFG.tmp"
{
  cat "$CFG.tmp"
  printf '%s\n' "$BEGIN"
  printf 'Host %s\n'            "$ALIAS"
  printf '    HostName %s\n'    "$CFG_HOSTNAME"
  [ -n "$DEV_USER" ]   && printf '    User %s\n' "$DEV_USER"
  [ "${DEV_PORT:-22}" != 22 ] && printf '    Port %s\n' "$DEV_PORT"
  printf '    IdentityFile %s\n' "$KEY"
  printf '    IdentitiesOnly yes\n'
  printf '%s\n' "$END"
} > "$CFG"
rm -f "$CFG.tmp"; chmod 600 "$CFG"
echo "wrote managed block for 'Host $ALIAS'."

# --- 7. verify the locked key — positively AND negatively ---------------------
say "Verifying the dv-only key"
# The verify uses BatchMode (passwordless key, no hang), so the host key must
# already be trusted. Step 1 trusted it for the common case; if --host-name points
# the bot at a DIFFERENT address than you admin-SSH'd over, seed that one too (TOFU
# — it's the same box you just reached, via another route).
if ! ssh-keygen -F "$CFG_HOSTNAME" >/dev/null 2>&1; then
  ssh-keyscan ${DEV_PORT_FLAG:+-p "$DEV_PORT_FLAG"} -H "$CFG_HOSTNAME" 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
fi
set +e
VER=$(ssh -o BatchMode=yes "$ALIAS" -- dv version 2>&1); VRC=$?
set -e
if [ "$VRC" -ne 0 ]; then
  echo "$VER" | sed 's/^/  /' >&2
  if printf '%s' "$VER" | grep -qiE 'permission denied|publickey'; then
    die "SSH rejected the dv-only key. The guard's authorized_keys entry didn't land for user
  '${DEV_USER:-?}' on the dev box — re-run, or check ~/.ssh/authorized_keys there."
  elif printf '%s' "$VER" | grep -qiE 'timed out|refused|no route|not known|unreachable'; then
    die "Can't reach the dev box as '$CFG_HOSTNAME'. If you SSH'd in over a different address than
  the bot should use, re-run with --host-name <reachable-address> (a stable Tailscale name is ideal)."
  elif printf '%s' "$VER" | grep -qiE 'dv.*not found|binary not found'; then
    die "Connected and the guard ran, but 'dv' isn't installed on the dev box (see step 5)."
  else
    die "'ssh $ALIAS -- dv version' failed (output above)."
  fi
fi
echo "  dv: $(printf '%s' "$VER" | head -1)"

# The guard is the authorization boundary — prove a non-dv command is REFUSED.
# A pre-existing unrestricted key for the same pubkey would silently defeat it.
if ssh -o BatchMode=yes "$ALIAS" -- echo guard-bypass >/dev/null 2>&1; then
  die "SECURITY: a non-'dv' command was NOT refused — the dv-only guard is being bypassed
  (likely a pre-existing, unrestricted authorized_keys entry for this key on the dev box).
  Remove that entry so only the 'restrict,command=...' line remains, then re-run."
fi
echo "  guard: non-dv commands are refused (good)."

# `dv list` needs Docker; report it but don't fail setup over a sleeping daemon.
if ssh -o BatchMode=yes "$ALIAS" -- dv list >/dev/null 2>&1; then
  echo "  docker: dv list works"
else
  warn "dv list failed — Docker on the dev box may be down. The link is set up; start Docker there."
fi

# --- 8. summary ---------------------------------------------------------------
printf '\n\033[1;32m== dv link ready ==\033[0m\n'
echo "  alias:     $ALIAS        (the bot runs everything as: ssh $ALIAS -- dv ...)"
PORT_NOTE=""; [ "${DEV_PORT:-22}" != 22 ] && PORT_NOTE=", port $DEV_PORT"
echo "  reaches:   $CFG_HOSTNAME${DEV_USER:+  (user $DEV_USER)}$PORT_NOTE"
echo "  key:       $KEY  (dv-only; private half stays on this server)"
echo "  skill:     $SKILL_DEST"
printf '\n  The dev box must be AWAKE for the bot to use this — best for attended use.\n'
echo "  Moved networks? Re-run with --host-name <new-address> to re-point the alias."
