#!/usr/bin/env bash
#
# Set up local dev: Discourse (host) <-> term-llm "stan" (local docker container),
# for both chat and forum actions. Idempotent — safe to re-run.
#
# Works on Linux and macOS. The container->host hop (stan -> Discourse) differs:
# on Linux it runs a tiny forwarder and may need a `ufw` rule (printed for you);
# on macOS it uses Docker Desktop's host.docker.internal and needs neither.
# See docs/local-dev.md for the full explanation.
#
# Usage:
#   scripts/setup-local-dev.sh              # set up / refresh
#   scripts/setup-local-dev.sh --new-key    # force a fresh Discourse API key for the bot
#
set -euo pipefail

DISCOURSE_DIR="${DISCOURSE_DIR:-$HOME/discourse}"
PLUGIN_DIR="${PLUGIN_DIR:-$HOME/work/second-brain}"
NEW_KEY=false
[ "${1:-}" = "--new-key" ] && NEW_KEY=true

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. discover the stan container + its network -----------------------------
say "Discovering stan container + network"
STAN="${STAN:-$(docker ps --format '{{.Names}}' | grep -E 'contain-stan.*app' | head -1)}"
[ -n "$STAN" ] || die "Could not find a running stan container (set STAN=... explicitly). docker ps:\n$(docker ps --format '{{.Names}}')"
NET=$(docker inspect "$STAN" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
GW=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Gateway}}')
SUBNET=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).Subnet}}')
echo "stan=$STAN  net=$NET  gateway=$GW  subnet=$SUBNET"

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

# --- 1. stan's bearer token (for the plugin -> stan direction) -----------------
say "Reading stan's WEB_TOKEN (chat: Discourse -> stan)"
WEB_TOKEN=$(docker exec -u agent "$STAN" sh -c 'pid=$(pgrep -f "serve web" | head -1); tr "\0" "\n" < /proc/$pid/environ | sed -n "s/^WEB_TOKEN=//p"' | head -1)
[ -n "$WEB_TOKEN" ] || die "Could not read WEB_TOKEN from the stan process."
echo "WEB_TOKEN=${WEB_TOKEN:0:8}…"

# --- 2. bot admin + Discourse API key (for the stan -> Discourse direction) ----
say "Ensuring bot is admin"
BOT_USERNAME=$(cd "$DISCOURSE_DIR" && bin/rails runner '
bot = SiteSetting.second_brain_bot_username.presence || "stan"
u = User.find_by(username_lower: bot.downcase) || SecondBrain::Bot.user
u.update!(admin: true) unless u.admin?
print u.username
' 2>/dev/null)
echo "bot=$BOT_USERNAME (admin)"

# Reuse the key already baked into stan's .zshenv unless --new-key was passed.
EXISTING_KEY=$(docker exec -u agent "$STAN" sh -c 'sed -n "s/^export DISCOURSE_API_KEY=//p" /home/agent/.zshenv 2>/dev/null' | head -1 || true)
if [ -n "$EXISTING_KEY" ] && [ "$NEW_KEY" = false ]; then
  API_KEY="$EXISTING_KEY"
  echo "Reusing existing Discourse API key (${API_KEY:0:8}…). Pass --new-key to rotate."
else
  say "Creating a fresh Discourse API key for $BOT_USERNAME"
  API_KEY=$(cd "$DISCOURSE_DIR" && bin/rails runner '
  u = User.find_by(username_lower: (SiteSetting.second_brain_bot_username.presence || "stan").downcase)
  k = ApiKey.create!(description: "second-brain dev forum actions", created_by: Discourse.system_user, user: u)
  print k.key
  ' 2>/dev/null)
  [ -n "$API_KEY" ] || die "Failed to create a Discourse API key."
  echo "API_KEY=${API_KEY:0:8}…"
fi

# --- 3. install the discourse skill into stan's volume ------------------------
say "Installing the discourse skill into stan's volume"
docker exec -u agent "$STAN" mkdir -p /home/agent/.config/term-llm/skills/discourse
docker exec -i -u agent "$STAN" sh -c 'cat > /home/agent/.config/term-llm/skills/discourse/SKILL.md' \
  < "$PLUGIN_DIR/term-llm/skills/discourse/SKILL.md"
echo "skill installed ($(docker exec -u agent "$STAN" sh -c 'wc -c < /home/agent/.config/term-llm/skills/discourse/SKILL.md') bytes)"

# --- 4. inject credentials into stan's env via .zshenv ------------------------
say "Writing stan's .zshenv (DISCOURSE_URL via $CONTAINER_HOST)"
docker exec -i -u agent "$STAN" sh -c 'cat > /home/agent/.zshenv' <<EOF
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
  if curl -s -o /dev/null -m 2 "http://$GW:3000/"; then
    echo "already reachable on $GW:3000 (forwarder up)"
  else
    nohup python3 "$PLUGIN_DIR/scripts/dev-discourse-forwarder.py" "$GW" 3000 127.0.0.1 3000 \
      > /tmp/sb-fwd.log 2>&1 &
    sleep 1
    echo "started forwarder (logs: /tmp/sb-fwd.log)"
  fi
else
  say "Skipping host forwarder (macOS: Docker Desktop routes host.docker.internal -> host)"
fi

# --- 6. plugin settings: point at local stan + enable forum actions ----------
say "Configuring plugin settings"
( cd "$DISCOURSE_DIR" && WEB_TOKEN="$WEB_TOKEN" bin/rails runner '
SiteSetting.second_brain_term_llm_url = "http://localhost:8081/chat"
SiteSetting.second_brain_term_llm_api_key = ENV["WEB_TOKEN"]
SiteSetting.second_brain_forum_actions_enabled = true
puts "  url=#{SiteSetting.second_brain_term_llm_url} forum_actions=#{SiteSetting.second_brain_forum_actions_enabled}"
' 2>/dev/null )

# --- 7. restart stan so it discovers the skill -------------------------------
say "Restarting stan (skills are scanned at startup)"
docker restart "$STAN" >/dev/null
for _ in $(seq 1 20); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/chat/)" = "200" ] && break; sleep 1
done
echo "stan back up"

# --- 8. verify the stan -> Discourse path ------------------------------------
say "Verifying stan -> Discourse path"
CODE=$(docker exec -u agent "$STAN" zsh -c \
  'curl -s -o /dev/null -w "%{http_code}" -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: $DISCOURSE_BOT_USERNAME" "$DISCOURSE_URL/session/current.json"' 2>/dev/null || echo 000)

if [ "$CODE" = "200" ]; then
  printf '\n\033[1;32m✓ All set — stan can act on the forum (HTTP %s).\033[0m\n' "$CODE"
  echo "  Try: open a chat with $BOT_USERNAME and ask it to create a topic."
else
  printf '\n\033[1;33m⚠ Chat is configured, but stan -> Discourse failed (HTTP %s).\033[0m\n' "$CODE"
  if [ "$USE_FORWARDER" != true ]; then
    echo "  macOS: ensure Discourse is up on 127.0.0.1:3000 and that your container"
    echo "  runtime provides host.docker.internal (Docker Desktop does; colima/podman"
    echo "  may need --add-host=host.docker.internal:host-gateway on the container)."
  elif systemctl is-active --quiet ufw 2>/dev/null; then
    echo "  ufw is active and likely dropping the container->host hop. Run (needs sudo):"
    printf '\n    \033[1msudo ufw allow from %s to any port 3000 proto tcp comment '"'"'dev: stan->discourse'"'"'\033[0m\n\n' "$SUBNET"
    echo "  then re-run this script (or just re-test)."
  else
    echo "  Check the forwarder (/tmp/sb-fwd.log) and that Discourse is up on 127.0.0.1:3000."
  fi
fi
