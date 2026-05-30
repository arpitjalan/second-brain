#!/usr/bin/env bash
#
# Set up local dev: Discourse (host) <-> a term-llm agent (local docker container),
# for both chat and forum actions. Idempotent — safe to re-run.
#
# The AGENT name is an argument (defaults to "stan"); nothing is hardcoded to one
# name. It drives both which container we talk to (term-llm-contain-<AGENT>-app-1)
# and the Discourse bot username, so chat and forum actions line up as one identity.
#
# Works on Linux and macOS. The container->host hop (agent -> Discourse) differs:
# on Linux it runs a tiny forwarder and may need a `ufw` rule (printed for you);
# on macOS it uses Docker Desktop's host.docker.internal and needs neither.
# See docs/local-dev.md for the full explanation.
#
# Usage:
#   scripts/setup-local-dev.sh                           # family agent "stan" (admin)
#   scripts/setup-local-dev.sh john                      # family agent "john"
#   scripts/setup-local-dev.sh stan-arpit --owner arpit  # a PERSONAL agent for arpit
#   scripts/setup-local-dev.sh stan --new-key            # rotate the Discourse API key
#
# A personal agent (--owner USER) is a TL4 (non-admin) bot private to that member.
# It gets a row in the agent registry (second_brain_agents) instead of the global
# family settings, so the family agent is left untouched.
#
set -euo pipefail

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

DISCOURSE_DIR="${DISCOURSE_DIR:-$HOME/discourse}"
PLUGIN_DIR="${PLUGIN_DIR:-$HOME/work/second-brain}"

# Parse args: an optional agent name (positional), --owner USER (personal agent),
# and --new-key. AGENT defaults to "stan" (the plugin's default bot username).
AGENT="stan"
NEW_KEY=false
OWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new-key)  NEW_KEY=true ;;
    --owner)    shift; OWNER="${1:-}"; [ -n "$OWNER" ] || die "--owner needs a username" ;;
    --owner=*)  OWNER="${1#--owner=}" ;;
    -*)         die "unknown option: $1  (usage: setup-local-dev.sh [AGENT] [--owner USER] [--new-key])" ;;
    *)          AGENT="$1" ;;
  esac
  shift
done
PERSONAL=false
[ -n "$OWNER" ] && PERSONAL=true

# --- 0. discover the agent's container + its network --------------------------
say "Discovering container for agent '$AGENT' + network"
CONTAINER="${CONTAINER:-$(docker ps --format '{{.Names}}' | grep -E "contain-${AGENT}.*app" | head -1)}"
[ -n "$CONTAINER" ] || die "No running container for agent '$AGENT' (expected ~ term-llm-contain-${AGENT}-app-1; pass the agent name or set CONTAINER=...). docker ps:\n$(docker ps --format '{{.Names}}')"
NET=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
GW=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Gateway}}')
SUBNET=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Subnet}}')
echo "agent=$AGENT  container=$CONTAINER  net=$NET  gateway=$GW  subnet=$SUBNET"

# Each `contain` publishes its internal :8081 to a distinct host port — discover it.
PORT=$(docker port "$CONTAINER" 8081 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1)
PORT="${PORT:-8081}"
AGENT_URL="http://localhost:${PORT}/chat"
echo "agent-url=$AGENT_URL  personal=$PERSONAL${OWNER:+  owner=$OWNER}"

# Container->host networking differs by OS. On Linux the container reaches the
# host via the bridge gateway, but only once we forward gateway:3000 ->
# 127.0.0.1:3000 (Discourse binds loopback). On macOS, Docker Desktop provides
# host.docker.internal, which routes straight to the host loopback — so no
# forwarder and no ufw rule are needed there.
case "$(uname -s)" in
  Darwin) CONTAINER_HOST="host.docker.internal"; USE_FORWARDER=false ;;
  *)      CONTAINER_HOST="$GW";                   USE_FORWARDER=true  ;;
esac
echo "host-os=$(uname -s)  container-reaches-host-via=$CONTAINER_HOST"

# --- 1. the agent's bearer token (for the plugin -> agent direction) ----------
say "Reading $AGENT's WEB_TOKEN (chat: Discourse -> $AGENT)"
WEB_TOKEN=$(docker exec -u agent "$CONTAINER" sh -c 'pid=$(pgrep -f "serve web" | head -1); tr "\0" "\n" < /proc/$pid/environ | sed -n "s/^WEB_TOKEN=//p"' | head -1)
[ -n "$WEB_TOKEN" ] || die "Could not read WEB_TOKEN from the $AGENT process."
echo "WEB_TOKEN=${WEB_TOKEN:0:8}…"

# --- 2. bot admin + Discourse API key (for the agent -> Discourse direction) ---
# Point the plugin's bot username at this agent, then ensure that bot user exists
# and is admin — keeping the term-llm agent and the Discourse bot one identity.
# We refuse a name Discourse can't use verbatim (reserved like "admin"/"support",
# or one it would sanitize): otherwise the setting and the real user would diverge
# and the plugin would mint a fresh bot on every call. Caveat: if a *human* already
# owns the chosen username, that account becomes the bot (and is granted admin) —
# so pick a name that isn't a real member's.
say "Ensuring the Discourse bot '$AGENT' exists ($([ "$PERSONAL" = true ] && echo "TL4, owned by $OWNER" || echo "admin"))"
BOT_USERNAME=$(cd "$DISCOURSE_DIR" && SB_AGENT="$AGENT" SB_PERSONAL="$PERSONAL" SB_OWNER="$OWNER" bin/rails runner '
name = ENV["SB_AGENT"]
existing = User.find_by(username_lower: name.downcase)
# If the name does not exist yet and Discourse would rename it on creation, bail.
if existing.nil? && UserNameSuggester.suggest(name).downcase != name.downcase
  print "UNUSABLE:#{UserNameSuggester.suggest(name)}"
elsif ENV["SB_PERSONAL"] == "true"
  owner = User.find_by(username_lower: ENV["SB_OWNER"].to_s.downcase)
  if owner.nil?
    print "NOOWNER"
  else
    u = existing || User.create!(
      username: UserNameSuggester.suggest(name),
      name: name.titleize,
      email: "#{name.downcase}@bot.second-brain.invalid",
      password: SecureRandom.hex(32),
      active: true,
      approved: true,
      trust_level: TrustLevel[4],
    )
    # Personal agents are TL4 (locked so it sticks), never admin.
    u.update!(admin: false, trust_level: TrustLevel[4], manual_locked_trust_level: TrustLevel[4])
    print u.username
  end
else
  SiteSetting.second_brain_bot_username = name
  u = SecondBrain::Bot.user            # find-or-create the family bot named SB_AGENT
  u.update!(admin: true) unless u.admin?
  print u.username
end
' 2>/dev/null)
case "$BOT_USERNAME" in
  UNUSABLE:*) die "agent name '$AGENT' is not a usable Discourse username (reserved or invalid — Discourse would rename it to '${BOT_USERNAME#UNUSABLE:}'). Pick a different agent name." ;;
  NOOWNER)    die "--owner user '$OWNER' not found in Discourse." ;;
  "")         die "Could not ensure the bot user '$AGENT' (is the Discourse dev env set up?)." ;;
esac
echo "bot=$BOT_USERNAME ($([ "$PERSONAL" = true ] && echo "TL4" || echo "admin"))"

# Reuse the key already baked into the agent's .zshenv unless --new-key was passed.
EXISTING_KEY=$(docker exec -u agent "$CONTAINER" sh -c 'sed -n "s/^export DISCOURSE_API_KEY=//p" /home/agent/.zshenv 2>/dev/null' | head -1 || true)
if [ -n "$EXISTING_KEY" ] && [ "$NEW_KEY" = false ]; then
  API_KEY="$EXISTING_KEY"
  echo "Reusing existing Discourse API key (${API_KEY:0:8}…). Pass --new-key to rotate."
else
  say "Creating a fresh Discourse API key for $BOT_USERNAME"
  API_KEY=$(cd "$DISCOURSE_DIR" && SB_BOT="$BOT_USERNAME" bin/rails runner '
  u = User.find_by(username_lower: ENV["SB_BOT"].downcase)
  k = ApiKey.create!(description: "second-brain dev forum actions", created_by: Discourse.system_user, user: u)
  print k.key
  ' 2>/dev/null)
  [ -n "$API_KEY" ] || die "Failed to create a Discourse API key."
  echo "API_KEY=${API_KEY:0:8}…"
fi

# --- 3. install the discourse skill into the agent's volume -------------------
say "Installing the discourse skill into $AGENT's volume"
docker exec -u agent "$CONTAINER" mkdir -p /home/agent/.config/term-llm/skills/discourse
docker exec -i -u agent "$CONTAINER" sh -c 'cat > /home/agent/.config/term-llm/skills/discourse/SKILL.md' \
  < "$PLUGIN_DIR/term-llm/skills/discourse/SKILL.md"
echo "skill installed ($(docker exec -u agent "$CONTAINER" sh -c 'wc -c < /home/agent/.config/term-llm/skills/discourse/SKILL.md') bytes)"

# --- 4. inject credentials into the agent's env via .zshenv -------------------
say "Writing $AGENT's .zshenv (DISCOURSE_URL via $CONTAINER_HOST)"
docker exec -i -u agent "$CONTAINER" sh -c 'cat > /home/agent/.zshenv' <<EOF
# second-brain dev: Discourse forum credentials for the discourse skill.
# Sourced by zsh on every shell-tool invocation. Managed by setup-local-dev.sh.
export DISCOURSE_URL=http://$CONTAINER_HOST:3000
export DISCOURSE_API_KEY=$API_KEY
export DISCOURSE_BOT_USERNAME=$BOT_USERNAME
EOF
echo "ok"

# --- 5. host forwarder so the container can reach Discourse (Linux only) ------
if [ "$USE_FORWARDER" = true ]; then
  say "Ensuring host forwarder $GW:3000 -> 127.0.0.1:3000"
  # Detect the listener with `ss`, not a curl through to Discourse — a curl probe
  # fails when Discourse is down even though the forwarder is up, which would make
  # us spawn a redundant one that just crashes with "address already in use".
  if ss -tln 2>/dev/null | grep -q "$GW:3000 "; then
    echo "forwarder already listening on $GW:3000"
  else
    nohup python3 "$PLUGIN_DIR/scripts/dev-discourse-forwarder.py" "$GW" 3000 127.0.0.1 3000 \
      > /tmp/sb-fwd.log 2>&1 &
    sleep 1
    if ss -tln 2>/dev/null | grep -q "$GW:3000 "; then
      echo "started forwarder (logs: /tmp/sb-fwd.log)"
    else
      echo "forwarder failed to bind — see /tmp/sb-fwd.log:"
      tail -3 /tmp/sb-fwd.log 2>/dev/null | sed 's/^/  /'
    fi
  fi
else
  say "Skipping host forwarder (macOS: Docker Desktop routes host.docker.internal -> host)"
fi

# --- 6. wire the agent: family -> global settings; personal -> registry row --
say "Configuring plugin settings"
if [ "$PERSONAL" = true ]; then
  ( cd "$DISCOURSE_DIR" && SB_BOT="$BOT_USERNAME" SB_URL="$AGENT_URL" SB_TOKEN="$WEB_TOKEN" SB_OWNER="$OWNER" bin/rails runner '
  bot = User.find_by(username_lower: ENV["SB_BOT"].downcase)
  owner = User.find_by(username_lower: ENV["SB_OWNER"].downcase)
  row = SecondBrain::AgentRecord.find_or_initialize_by(bot_user_id: bot.id)
  row.update!(
    term_llm_url: ENV["SB_URL"],
    term_llm_token: ENV["SB_TOKEN"],
    agent_name: bot.username,
    owner_user_id: owner.id,
    forum_role: "tl4",
  )
  SiteSetting.second_brain_forum_actions_enabled = true
  puts "  registry: #{bot.username} -> #{ENV["SB_URL"]} (owner=#{owner.username}, tl4)"
  ' 2>/dev/null )
else
  ( cd "$DISCOURSE_DIR" && SB_URL="$AGENT_URL" WEB_TOKEN="$WEB_TOKEN" bin/rails runner '
  SiteSetting.second_brain_term_llm_url = ENV["SB_URL"]
  SiteSetting.second_brain_term_llm_api_key = ENV["WEB_TOKEN"]
  SiteSetting.second_brain_forum_actions_enabled = true
  puts "  url=#{SiteSetting.second_brain_term_llm_url} forum_actions=#{SiteSetting.second_brain_forum_actions_enabled}"
  ' 2>/dev/null )
fi

# --- 7. restart the agent so it discovers the skill --------------------------
say "Restarting $AGENT (skills are scanned at startup)"
docker restart "$CONTAINER" >/dev/null
for _ in $(seq 1 20); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "${AGENT_URL}/")" = "200" ] && break; sleep 1
done
echo "$AGENT back up"

# --- 8. verify the agent -> Discourse path -----------------------------------
say "Verifying $AGENT -> Discourse path"
CODE=$(docker exec -u agent "$CONTAINER" zsh -c \
  'curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -m 8 -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" "$DISCOURSE_URL/session/current.json"' 2>/dev/null)
CODE=${CODE:-000}   # curl prints 000 on connect failure; default if the exec itself produced nothing

if [ "$CODE" = "200" ]; then
  printf '\n\033[1;32m✓ All set — %s can act on the forum (HTTP %s).\033[0m\n' "$AGENT" "$CODE"
  echo "  Try: open a chat with $BOT_USERNAME and ask it to create a topic."
else
  printf '\n\033[1;33m⚠ Chat is configured, but %s -> Discourse failed (HTTP %s).\033[0m\n' "$AGENT" "$CODE"
  # Diagnose the real cause instead of always blaming ufw. Check the most common
  # culprit first: the Discourse dev server simply isn't running.
  if ! curl -s -o /dev/null -m 3 http://127.0.0.1:3000/; then
    echo "  Discourse isn't responding on 127.0.0.1:3000 — this is almost always the"
    echo "  reason (the forwarder has nothing to forward to). Start it, then re-test:"
    printf '\n    \033[1mcd %s && bin/dev\033[0m   # wait for \"Listening on 127.0.0.1:3000\"\n\n' "$DISCOURSE_DIR"
  elif [ "$USE_FORWARDER" != true ]; then
    echo "  macOS: Discourse is up, so check that your container runtime provides"
    echo "  host.docker.internal (Docker Desktop does; colima/podman may need"
    echo "  --add-host=host.docker.internal:host-gateway on the container)."
  elif ! ss -tln 2>/dev/null | grep -q "$GW:3000 "; then
    echo "  Discourse is up, but the host forwarder isn't listening on $GW:3000."
    echo "  See /tmp/sb-fwd.log:"
    tail -3 /tmp/sb-fwd.log 2>/dev/null | sed 's/^/    /'
  elif systemctl is-active --quiet ufw 2>/dev/null; then
    echo "  Discourse + forwarder are up, so ufw is likely dropping the container->host"
    echo "  hop. Run (needs sudo), then re-test:"
    printf '\n    \033[1msudo ufw allow from %s to any port 3000 proto tcp comment '"'"'second-brain dev: container->discourse'"'"'\033[0m\n\n' "$SUBNET"
  else
    echo "  Discourse, forwarder, and firewall look fine — check the bot's API key /"
    echo "  username in $AGENT's .zshenv (re-run with --new-key to rotate the key)."
  fi
fi
